-- KO Catchup: a spoiler-safe AI recap of the book up to the current
-- reading position. Extraction runs in the main process (the pattern proven
-- by the Assistant plugin; crengine calls in a forked child are unverified);
-- the blocking network call runs in a cancellable Trapper subprocess.
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Cache = require("kocatchup_cache")
local Extractor = require("kocatchup_extractor")
local Llm = require("kocatchup_llm")
local Prompts = require("kocatchup_prompts")
local Settings = require("kocatchup_settings")
local Updater = require("kocatchup_updater")

-- Real updater seams, bound lazily at the first real check so they never
-- pull device-only modules under unit tests (each closure requires on call).
local function real_updater_transport(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local chunks = {}
    local reqt = {
        url = req.url,
        method = req.method or "GET",
        headers = req.headers,
        sink = ltn12.sink.table(chunks),
    }
    if req.url:lower():sub(1, 6) == "https:" then
        -- Pass the TLS-parameterized factory on the caller's table so
        -- verification survives GitHub's cross-host redirect (KTD2): luasocket
        -- carries only `create` to the redirected hop.
        reqt.create = require("ssl.https").tcp{
            verify = "peer",
            cafile = Llm.find_ca_bundle(),
            protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3" },
        }
    end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, code = http.request(reqt)
    socketutil:reset_timeout()
    if not ok then return nil, tostring(code) end
    return table.concat(chunks), code
end

local function real_updater_extract(zip_path, dest)
    local ok_arc, Archiver = pcall(require, "ffi/archiver")
    if not ok_arc then return nil, "extract_failed" end
    local util = require("ffi/util")
    util.makePath(dest)
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then return nil, "extract_failed" end
    local total = 0
    for entry in arc:iterate() do
        if Updater.unsafe_entry(entry.path) then
            arc:close(); return nil, "unsafe_entry"
        end
        total = total + (tonumber(entry.size) or 0)
        if total > Updater.MAX_BYTES then
            arc:close(); return nil, "extract_failed"
        end
        if not arc:extractToPath(entry.path, dest .. "/" .. entry.path) then
            arc:close(); return nil, "extract_failed"
        end
    end
    arc:close()
    return true
end

local function real_updater_fs()
    local function lfs() return require("libs/libkoreader-lfs") end
    local function ffiutil() return require("ffi/util") end
    return {
        exists = function(p) return lfs().attributes(p, "mode") ~= nil end,
        purge = function(p) pcall(function() ffiutil().purgeDir(p) end) end,
        rename = function(a, b) return os.rename(a, b) end,
        write = function(p, bytes)
            local dir = p:match("^(.*)[/\\][^/\\]+$")
            if dir then ffiutil().makePath(dir) end
            local f = io.open(p, "wb")
            if f then f:write(bytes); f:close() end
        end,
        read = function(p)
            local f = io.open(p, "r")
            if not f then return nil end
            local t = f:read("*a"); f:close(); return t
        end,
        loadcheck = function(p) return loadfile(p) ~= nil end,
    }
end

local KoCatchup = WidgetContainer:extend{
    name = "kocatchup",
    is_doc_only = true,
    VERSION = "0.5.0", -- keep in sync with _meta.lua and the release tag
    PREGEN_DELAY_S = 20, -- background pre-generation waits this long after book open
    OFFER_DELAY_S = 2, -- catch-up offer check runs this long after open/resume
    ROLL_LIMIT = 10, -- drift guard: max rolls before a re-grounded refresh
    MAX_SANE_BREAK_S = 10 * 365 * 86400, -- beyond this, assume a broken clock
}

-- Maps typed failures to user-facing messages. Every failure path shows a
-- specific, actionable message (R9); kept as a pure function for tests.
function KoCatchup.error_message(err, code)
    local messages = {
        no_api_key = _("No API key configured. Open KO Catchup → Settings and set your provider API key."),
        no_text = _("No readable text found before your current position. Image-only documents can't be recapped."),
        too_short = _("You're too early in this book for a recap — read a little further first."),
        timeout = _("The recap service didn't respond in time. Check your connection and try again."),
        bad_response = _("The recap service returned an unexpected response. Try again, or check your provider and model settings."),
        tls_error = _("Secure connection to the recap service failed (certificate verification). Check your base URL."),
    }
    if err == "http_error" then
        return _("The recap service returned an error.") .. " (HTTP " .. tostring(code) .. ")"
    end
    return messages[err] or (_("Recap failed: ") .. tostring(err))
end

function KoCatchup:onDispatcherRegisterActions()
    Dispatcher:registerAction("kocatchup_generate", {
        category = "none",
        event = "KoCatchupGenerate",
        title = _("KO Catchup: recap"),
        reader = true,
    })
end

function KoCatchup:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KoCatchup:addToMainMenu(menu_items)
    menu_items.kocatchup = {
        text = _("KO Catchup"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Generate recap"),
                callback = function() self:onKoCatchupGenerate() end,
            },
            {
                text = _("Settings"),
                sub_item_table = self:getSettingsMenuItems(),
            },
        },
    }
end

function KoCatchup:getSettingsMenuItems()
    local items = Settings.getMenuItems()
    table.insert(items, {
        text = _("Regenerate full recap"),
        callback = function() self:onRegenerateFullRecap() end,
    })
    table.insert(items, {
        text = _("Check for updates"),
        keep_menu_open = true,
        callback = function() self:onCheckForUpdates() end,
    })
    return items
end

-- Typed updater failures → user-facing messages (kept separate from recap
-- errors; pure for tests).
function KoCatchup.updater_message(err, code)
    local messages = {
        tls_unavailable = _("A verified secure connection is required to download updates, and none is available on this device. Please update via USB instead."),
        no_asset = _("The latest release has no installable package yet. Try again later."),
        download_failed = _("The update download didn't complete. Check your connection and try again."),
        digest_mismatch = _("The downloaded update failed its integrity check and was discarded. Your installed version is unchanged."),
        unsafe_entry = _("The update package was rejected as unsafe and discarded. Your installed version is unchanged."),
        extract_failed = _("The update package could not be unpacked (it may be unsupported on this build). Your installed version is unchanged."),
        validate_failed = _("The downloaded update was incomplete and was discarded. Your installed version is unchanged."),
        bad_response = _("The update service returned an unexpected response. Try again later."),
    }
    if err == "http_error" then
        return _("Couldn't reach the update service.") .. " (HTTP " .. tostring(code) .. ")"
    end
    return messages[err] or (_("Update failed: ") .. tostring(err))
end

function KoCatchup:ensureUpdaterSeams()
    if Updater.transport then return end -- tests inject their own seams
    Updater.transport = real_updater_transport
    Updater.hasher = function(bytes) return require("ffi/sha2").sha256(bytes) end
    Updater.archiver = { extract = real_updater_extract }
    Updater.fs = real_updater_fs()
end

function KoCatchup:updaterPaths(rel)
    local live = self.path or "."
    local parent = live:match("^(.*)[/\\][^/\\]+$") or "."
    local staging = parent .. "/kocatchup.staging"
    return {
        live = live,
        staging = staging,
        staged_plugin = staging .. "/kocatchup.koplugin",
        backup = parent .. "/kocatchup.bak", -- not *.koplugin: loader must ignore it
        download = staging .. "/kocatchup-update.zip",
        url = rel.asset_url,
        digest = rel.digest,
        tag = rel.version,
    }
end

-- Manual update check. Verified TLS is mandatory: with no CA bundle we abort
-- before any network request rather than downloading code unverified.
function KoCatchup:onCheckForUpdates()
    self:ensureUpdaterSeams()
    if not Llm.find_ca_bundle() then
        UIManager:show(InfoMessage:new{ text = self.updater_message("tls_unavailable") })
        return true
    end
    Trapper:wrap(function()
        Trapper:info(_("KO Catchup: checking for updates…"))
        local rel, err, code = Updater.check(self.VERSION)
        if Trapper.clear then Trapper:clear() end
        if not rel then
            UIManager:show(InfoMessage:new{ text = self.updater_message(err, code) })
            return
        end
        if not rel.newer then
            UIManager:show(InfoMessage:new{
                text = _("KO Catchup ") .. self.VERSION .. _(" is up to date."),
            })
            return
        end
        -- ConfirmBox is non-blocking; its callback opens a fresh wrap for the
        -- install pipeline (matching the generate flow's structure).
        UIManager:show(ConfirmBox:new{
            text = _("Update available: ") .. self.VERSION .. " \u{2192} " .. rel.version
                .. _(". Download and install it now?"),
            ok_text = _("Update"),
            cancel_text = _("Not now"),
            ok_callback = function() self:installUpdate(rel) end,
        })
    end)
    return true
end

function KoCatchup:installUpdate(rel)
    local paths = self:updaterPaths(rel)
    Trapper:wrap(function()
        Trapper:info(_("KO Catchup: downloading and installing update…"))
        local ok, err = Updater.run(paths)
        if Trapper.clear then Trapper:clear() end
        if ok then
            local msg = _("KO Catchup updated to ") .. rel.version
                .. _(". Restart KOReader to use the new version.")
            local restarted = pcall(function() UIManager:askForRestart(msg) end)
            if not restarted then
                UIManager:show(InfoMessage:new{ text = msg })
            end
        else
            UIManager:show(InfoMessage:new{ text = self.updater_message(err) })
        end
    end)
end

-- Current position as an opaque identity key plus a comparable percent.
function KoCatchup:getPositionInfo()
    local doc = self.ui.document
    local pos = {}
    local count = 1
    pcall(function() count = doc:getPageCount() or 1 end)
    if doc.info and doc.info.has_pages then
        local page = 1
        pcall(function() page = self.ui.view.state.page or 1 end)
        pos.key = "page:" .. tostring(page)
        pos.page = page
        pos.percent = page / math.max(1, count)
    else
        local xp = doc:getXPointer()
        pos.key = "xp:" .. tostring(xp)
        pos.xpointer = xp
        local page
        pcall(function() page = doc:getPageFromXPointer(xp) end)
        pos.page = page
        pos.percent = page and (page / math.max(1, count)) or nil
    end
    return pos
end

-- Decides how to generate given the cached entry, the current position, and
-- the active settings. Pure and unit-testable: cached_page is resolved by the
-- caller (entry.page, or getPageFromXPointer on the recovered xpointer).
-- Returns "full" | "roll" | "reground" (+ the delta-from position for rolls
-- and re-grounds' previous recap source).
function KoCatchup.decide_generation(entry, pos, cfg, cached_page)
    if not entry then return "full" end
    local from = Cache.rollable_position(entry)
    if not from then return "full" end
    -- Cache.compare only reports settings_changed at the same position;
    -- re-check here so an advanced reader with new settings gets a full run.
    if entry.model ~= cfg.model or entry.recap_length ~= cfg.recap_length then
        return "full"
    end
    -- "behind" is a fallthrough classification; prove the delta actually runs
    -- forward before extracting a range, else a reversed range could surface
    -- text from ahead of the reader.
    local cur_page = tonumber(pos.page)
    cached_page = tonumber(cached_page)
    if not (cached_page and cur_page and cached_page < cur_page) then
        return "full"
    end
    local rolls, chars = Cache.counters(entry)
    local window = tonumber(cfg.max_input_chars) or 100000
    if rolls >= KoCatchup.ROLL_LIMIT or chars >= window then
        return "reground", from
    end
    return "roll", from
end

function KoCatchup:onKoCatchupGenerate()
    local cfg = Settings.load()

    -- Local checks first: no Wi-Fi prompt for problems the network can't fix.
    local cfg_err = Llm.check_config(cfg)
    if cfg_err then
        UIManager:show(InfoMessage:new{ text = self.error_message(cfg_err) })
        return true
    end
    local pos = self:getPositionInfo()
    if pos.percent and pos.percent <= 0.02 then
        UIManager:show(InfoMessage:new{ text = self.error_message("too_short") })
        return true
    end

    local entry = Cache.read(self.ui.doc_settings)
    local state = Cache.compare(entry, pos, cfg)

    if state == "hit" then
        self:showRecap(entry.recap)
        return true
    end
    if state == "ahead" then
        -- Cached recap covers a LATER point than the reader is at now.
        -- Never show it by default — that's the spoiler R2 forbids.
        UIManager:show(ConfirmBox:new{
            text = _("Your saved recap covers a later point in this book than where you are now — showing it could spoil what's ahead. Generate a fresh recap for your current position?"),
            ok_text = _("Generate new recap"),
            ok_callback = function() self:generate(cfg, pos, nil, { force_full = true }) end,
        })
        return true
    end
    if state == "behind" or state == "settings_changed" then
        UIManager:show(ConfirmBox:new{
            text = state == "behind"
                and _("You've read further since this recap was saved. Update it with what you've read, or show the saved one?")
                or _("Your recap settings changed since this recap was saved. Generate a new recap, or show the saved one?"),
            ok_text = state == "behind" and _("Update recap") or _("Generate"),
            cancel_text = _("Show saved"),
            ok_callback = function() self:generate(cfg, pos, entry) end,
            cancel_callback = function() self:showRecap(entry.recap) end,
        })
        return true
    end

    self:generate(cfg, pos)
    return true
end

-- Settings escape hatch: force a from-scratch recap at the current position.
-- Runs the same entry checks as the normal trigger, and keeps the spoiler
-- guard when the cache covers a later point than the reader is at now.
function KoCatchup:onRegenerateFullRecap()
    local cfg = Settings.load()
    local cfg_err = Llm.check_config(cfg)
    if cfg_err then
        UIManager:show(InfoMessage:new{ text = self.error_message(cfg_err) })
        return true
    end
    local pos = self:getPositionInfo()
    if pos.percent and pos.percent <= 0.02 then
        UIManager:show(InfoMessage:new{ text = self.error_message("too_short") })
        return true
    end
    local entry = Cache.read(self.ui.doc_settings)
    local state = Cache.compare(entry, pos, cfg)
    if state == "ahead" then
        UIManager:show(ConfirmBox:new{
            text = _("Your saved recap covers a later point in this book than where you are now — regenerating will replace it with one for your current position. Continue?"),
            ok_text = _("Generate new recap"),
            ok_callback = function() self:generate(cfg, pos, nil, { force_full = true }) end,
        })
        return true
    end
    self:generate(cfg, pos, nil, { force_full = true })
    return true
end

-- Session lifecycle. A "session" starts at book open (onReaderReady) or
-- device resume, and ends at document close or device suspend — on e-ink,
-- suspending with the book open is the dominant way reading breaks happen.
-- Session start captures the position and schedules the opt-in background
-- tasks; session end records the last-read baseline (only when the position
-- moved, so a trivial peek never erases a real break) and unschedules tasks.
function KoCatchup:onSessionStart()
    local ok, pos = pcall(function() return self:getPositionInfo() end)
    self._session_start_key = ok and pos and pos.key or nil
    local cfg = Settings.load()
    if cfg.auto_generate then
        self._pregen_task = function() self:pregenerate() end
        UIManager:scheduleIn(self.PREGEN_DELAY_S, self._pregen_task)
    end
    if cfg.auto_offer then
        self._offer_task = function() self:maybeOfferCatchup() end
        UIManager:scheduleIn(self.OFFER_DELAY_S, self._offer_task)
    end
end

function KoCatchup:onSessionEnd()
    if self.ui and self.ui.document and self.ui.doc_settings then
        local ok, pos = pcall(function() return self:getPositionInfo() end)
        -- Write the baseline only when the session made progress; when the
        -- session-start position is unknown, err toward writing.
        if ok and pos and (not self._session_start_key or pos.key ~= self._session_start_key) then
            Cache.touch_last_read(self.ui.doc_settings, os.time())
        end
    end
    if self._pregen_task then
        UIManager:unschedule(self._pregen_task)
        self._pregen_task = nil
    end
    if self._offer_task then
        UIManager:unschedule(self._offer_task)
        self._offer_task = nil
    end
end

KoCatchup.onReaderReady = KoCatchup.onSessionStart
KoCatchup.onResume = KoCatchup.onSessionStart
KoCatchup.onCloseDocument = KoCatchup.onSessionEnd
KoCatchup.onSuspend = KoCatchup.onSessionEnd

-- The catch-up offer (opt-in via auto_offer): after a qualifying break, ask
-- once per open/resume whether to catch up. All guards re-evaluate at fire
-- time; any failure means silence — an offer that leads to an error message
-- is worse than no offer.
function KoCatchup:maybeOfferCatchup()
    self._offer_task = nil
    if not self.ui or not self.ui.document then return end
    local cfg = Settings.load()
    if not cfg.auto_offer then return end
    if Llm.check_config(cfg) then return end
    local baseline = Cache.last_read(self.ui.doc_settings)
    if not baseline then return end
    local elapsed = os.time() - baseline
    if elapsed <= 0 or elapsed > self.MAX_SANE_BREAK_S then return end
    if elapsed < (tonumber(cfg.auto_offer_days) or 3) * 86400 then return end
    local pos = self:getPositionInfo()
    if pos.percent and pos.percent <= 0.02 then return end

    UIManager:show(ConfirmBox:new{
        text = _("You've been away from this book for a while. Catch up on the story so far?"),
        ok_text = _("Catch up"),
        cancel_text = _("Not now"),
        ok_callback = function()
            -- Acceptance makes this session's pre-generation redundant; a
            -- pending pregen firing mid-generation would double-spend.
            if self._pregen_task then
                UIManager:unschedule(self._pregen_task)
                self._pregen_task = nil
            end
            self:onKoCatchupGenerate()
        end,
        -- Decline/dismiss: nothing persisted; an unread session preserves
        -- the baseline, so the offer returns at the next qualifying start.
    })
end

function KoCatchup:pregenerate()
    self._pregen_task = nil
    if not self.ui or not self.ui.document then return end
    -- Re-check everything at fire time; settings may have changed since open.
    local cfg = Settings.load()
    if not cfg.auto_generate then return end
    if Llm.check_config(cfg) then return end
    if not NetworkMgr:isOnline() then return end -- background work never prompts for Wi-Fi
    local pos = self:getPositionInfo()
    if pos.percent and pos.percent <= 0.02 then return end
    local entry = Cache.read(self.ui.doc_settings)
    local state = Cache.compare(entry, pos, cfg)
    -- Only when a fresh recap is genuinely useful; "ahead" is skipped so a
    -- backward jump never silently overwrites the later-position recap.
    if state ~= "miss" and state ~= "behind" and state ~= "settings_changed" then return end

    Trapper:wrap(function()
        self:doGenerate(cfg, pos, entry, { background = true })
    end)
end

function KoCatchup:generate(cfg, pos, entry, opts)
    -- On a declined Wi-Fi prompt, runWhenOnline drops the callback silently;
    -- KOReader's own connectivity UI is the user feedback in that case.
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self:doGenerate(cfg, pos, entry, opts)
        end)
    end)
end

-- The single generation body shared by the manual trigger, the escape hatch,
-- and background pre-generation (opts.background: no UI, silent failures,
-- invisible trap widget). Mode comes from decide_generation unless
-- opts.force_full pins a from-scratch run.
function KoCatchup:doGenerate(cfg, pos, entry, opts)
    opts = opts or {}
    local bg = opts.background

    local mode, from = "full", nil
    if not opts.force_full and entry then
        local cached_page = tonumber(entry.page)
        if not cached_page then
            local rollable = Cache.rollable_position(entry)
            if rollable and rollable.xpointer then
                pcall(function()
                    cached_page = self.ui.document:getPageFromXPointer(rollable.xpointer)
                end)
            end
        end
        mode, from = KoCatchup.decide_generation(entry, pos, cfg, cached_page)
    end

    local prompt, delta_len
    if mode == "roll" then
        if not bg then Trapper:info(_("KO Catchup: reading what's new…")) end
        -- Manual updates roll any non-empty delta; background keeps the
        -- default minimum so trivial deltas are skipped silently.
        local delta_opts = { max_input_chars = cfg.max_input_chars }
        if not bg then delta_opts.min_delta_chars = 0 end
        local extracted = Extractor.extract_delta(self.ui, from, delta_opts)
        if not extracted then
            if bg then return end
            mode = "full" -- manual fallback: empty range → from-scratch recap
        else
            delta_len = #extracted.text
            prompt = Prompts.build_update(extracted.metadata, entry.recap,
                extracted.text, cfg.recap_length)
        end
    end
    if not prompt then -- full or reground
        if not bg then Trapper:info(_("KO Catchup: reading the book text…")) end
        local extracted, extract_err = Extractor.extract(self.ui, {
            max_input_chars = cfg.max_input_chars,
        })
        if not extracted then
            if not bg then
                if Trapper.clear then Trapper:clear() end
                UIManager:show(InfoMessage:new{ text = self.error_message(extract_err) })
            end
            return
        end
        if mode == "reground" then
            prompt = Prompts.build_reground(extracted.metadata, extracted.text,
                entry.recap, cfg.recap_length)
        else
            mode = "full"
            prompt = Prompts.build(extracted.metadata, extracted.text, cfg.recap_length)
        end
    end

    local completed, result = Trapper:dismissableRunInSubprocess(function()
        return Llm.complete(cfg, prompt)
    end, bg and false or _("KO Catchup: generating recap…\nTap to cancel."))

    if not completed then
        if not bg then
            UIManager:show(InfoMessage:new{ text = _("Recap generation cancelled.") })
        end
        return
    end
    if type(result) ~= "table" or not result.ok then
        local err = type(result) == "table" and result.err or "unknown"
        local code = type(result) == "table" and result.code or nil
        logger.warn("kocatchup: generation failed:", err, code)
        if not bg then
            UIManager:show(InfoMessage:new{ text = self.error_message(err, code) })
        end
        return
    end

    local rolls, chars = Cache.counters(entry)
    Cache.write(self.ui.doc_settings, {
        recap = result.recap,
        position = pos.key,
        percent = pos.percent,
        xpointer = pos.xpointer,
        page = pos.page,
        model = cfg.model,
        recap_length = cfg.recap_length,
        timestamp = os.time(),
        -- Rolls accumulate drift budget; full and re-grounded runs reset it.
        roll_count = mode == "roll" and (rolls + 1) or 0,
        rolled_chars = mode == "roll" and (chars + (delta_len or 0)) or 0,
    })
    if bg then
        logger.dbg("kocatchup: background recap cached (" .. mode .. ")")
    else
        self:showRecap(result.recap)
    end
end

function KoCatchup:showRecap(recap)
    local title = _("KO Catchup")
    pcall(function()
        local props = self.ui.document:getProps()
        if props and props.title and props.title ~= "" then
            title = props.title .. " — " .. _("KO Catchup")
        end
    end)
    UIManager:show(TextViewer:new{
        title = title,
        text = recap,
    })
end

return KoCatchup
