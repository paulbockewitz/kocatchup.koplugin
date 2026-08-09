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
                sub_item_table = Settings.getMenuItems(),
            },
        },
    }
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
        pos.percent = page / math.max(1, count)
    else
        local xp = doc:getXPointer()
        pos.key = "xp:" .. tostring(xp)
        local page
        pcall(function() page = doc:getPageFromXPointer(xp) end)
        pos.percent = page and (page / math.max(1, count)) or nil
    end
    return pos
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
            ok_callback = function() self:generate(cfg, pos) end,
        })
        return true
    end
    if state == "behind" or state == "settings_changed" then
        UIManager:show(ConfirmBox:new{
            text = state == "behind"
                and _("You've read further since this recap was saved. Generate an updated recap, or show the saved one?")
                or _("Your recap settings changed since this recap was saved. Generate a new recap, or show the saved one?"),
            ok_text = _("Generate"),
            cancel_text = _("Show saved"),
            ok_callback = function() self:generate(cfg, pos) end,
            cancel_callback = function() self:showRecap(entry.recap) end,
        })
        return true
    end

    self:generate(cfg, pos)
    return true
end

function KoCatchup:generate(cfg, pos)
    -- On a declined Wi-Fi prompt, runWhenOnline drops the callback silently;
    -- KOReader's own connectivity UI is the user feedback in that case.
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self:doGenerate(cfg, pos)
        end)
    end)
end

function KoCatchup:doGenerate(cfg, pos)
    Trapper:info(_("KO Catchup: reading the book text…"))
    local extracted, extract_err = Extractor.extract(self.ui, {
        max_input_chars = cfg.max_input_chars,
    })
    if not extracted then
        if Trapper.clear then Trapper:clear() end
        UIManager:show(InfoMessage:new{ text = self.error_message(extract_err) })
        return
    end

    local prompt = Prompts.build(extracted.metadata, extracted.text, cfg.recap_length)
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        return Llm.complete(cfg, prompt)
    end, _("KO Catchup: generating recap…\nTap to cancel."))

    if not completed then
        UIManager:show(InfoMessage:new{ text = _("Recap generation cancelled.") })
        return
    end
    if type(result) ~= "table" or not result.ok then
        local err = type(result) == "table" and result.err or "unknown"
        local code = type(result) == "table" and result.code or nil
        logger.warn("kocatchup: generation failed:", err, code)
        UIManager:show(InfoMessage:new{ text = self.error_message(err, code) })
        return
    end

    Cache.write(self.ui.doc_settings, {
        recap = result.recap,
        position = pos.key,
        percent = pos.percent,
        model = cfg.model,
        recap_length = cfg.recap_length,
        timestamp = os.time(),
    })
    self:showRecap(result.recap)
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
