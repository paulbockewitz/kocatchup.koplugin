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

local KoCatchup = WidgetContainer:extend{
    name = "kocatchup",
    is_doc_only = true,
    VERSION = "0.3.0", -- keep in sync with _meta.lua and the release tag
    PREGEN_DELAY_S = 20, -- background pre-generation waits this long after book open
    ROLL_LIMIT = 10, -- drift guard: max rolls before a re-grounded refresh
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
    return items
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

-- Background pre-generation (opt-in via the auto_generate setting): schedule
-- a silent recap attempt shortly after a book opens so a later manual tap is
-- an instant cache hit. Never prompts, never shows UI, never wakes Wi-Fi.
function KoCatchup:onReaderReady()
    local cfg = Settings.load()
    if not cfg.auto_generate then return end
    self._pregen_task = function() self:pregenerate() end
    UIManager:scheduleIn(self.PREGEN_DELAY_S, self._pregen_task)
end

function KoCatchup:onCloseDocument()
    if self._pregen_task then
        UIManager:unschedule(self._pregen_task)
        self._pregen_task = nil
    end
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
