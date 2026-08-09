-- Settings persistence (LuaSettings file under KOReader's settings dir, so
-- config survives plugin reinstalls) and the settings submenu.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local _ = require("gettext")

local Settings = {}

Settings.defaults = {
    provider = "openai",        -- "openai" (any OpenAI-compatible endpoint) | "anthropic"
    base_url = "",              -- blank = provider default
    model = "gpt-4o-mini",
    api_key = "",
    recap_length = "standard",  -- short | standard | detailed
    max_input_chars = 100000,   -- tail window sent to the model
}

function Settings.path()
    return DataStorage:getSettingsDir() .. "/kocatchup.lua"
end

function Settings.load()
    local store = LuaSettings:open(Settings.path())
    local cfg = store:readSetting("config")
    local merged = {}
    for k, v in pairs(Settings.defaults) do merged[k] = v end
    if type(cfg) == "table" then
        for k, v in pairs(cfg) do merged[k] = v end
    end
    return merged
end

function Settings.save(cfg)
    local store = LuaSettings:open(Settings.path())
    store:saveSetting("config", cfg)
    store:flush()
end

local function update(key, value)
    local cfg = Settings.load()
    cfg[key] = value
    Settings.save(cfg)
end

-- True when the URL sends traffic over plain HTTP to a non-local host —
-- the API key and book text would travel unencrypted.
function Settings.is_insecure_url(url)
    if type(url) ~= "string" then return false end
    if url:sub(1, 5):lower() ~= "http:" then return false end
    local host = url:match("^[hH][tT][tT][pP]://%[?([^/%]:]+)")
    if not host then return true end
    host = host:lower()
    return not (host == "localhost" or host == "127.0.0.1" or host == "::1")
end

local function edit_field(title, key, hint)
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local cfg = Settings.load()
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(cfg[key] or ""),
        input_hint = hint,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    UIManager:close(dialog)
                    if key == "max_input_chars" then
                        value = tonumber(value) or Settings.defaults.max_input_chars
                    end
                    if key == "base_url" and Settings.is_insecure_url(value) then
                        UIManager:show(ConfirmBox:new{
                            text = _("This base URL uses plain HTTP to a remote host — your API key and book text would be sent unencrypted. Save anyway?"),
                            ok_text = _("Save anyway"),
                            ok_callback = function() update(key, value) end,
                        })
                    else
                        update(key, value)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

local function choice_items(key, choices)
    local items = {}
    for _idx, c in ipairs(choices) do
        items[#items + 1] = {
            text = c.text,
            checked_func = function() return Settings.load()[key] == c.value end,
            callback = function() update(key, c.value) end,
            radio = true,
            keep_menu_open = true,
        }
    end
    return items
end

function Settings.getMenuItems()
    return {
        {
            text = _("Provider"),
            sub_item_table = choice_items("provider", {
                { text = _("OpenAI-compatible (OpenAI, OpenRouter, Groq, Ollama…)"), value = "openai" },
                { text = _("Anthropic"), value = "anthropic" },
            }),
        },
        {
            text = _("API key"),
            keep_menu_open = true,
            callback = function()
                edit_field(_("API key"), "api_key",
                    _("Provider API key (may be blank for local Ollama)"))
            end,
        },
        {
            text = _("Base URL"),
            keep_menu_open = true,
            callback = function()
                edit_field(_("Base URL"), "base_url",
                    _("Blank = provider default. Ollama: http://localhost:11434/v1"))
            end,
        },
        {
            text = _("Model"),
            keep_menu_open = true,
            callback = function()
                edit_field(_("Model"), "model", _("e.g. gpt-4o-mini, claude-haiku-4-5"))
            end,
        },
        {
            text = _("Recap length"),
            sub_item_table = choice_items("recap_length", {
                { text = _("Short (~150 words)"), value = "short" },
                { text = _("Standard (~400 words)"), value = "standard" },
                { text = _("Detailed (~800 words)"), value = "detailed" },
            }),
        },
        {
            text = _("Max input size"),
            keep_menu_open = true,
            callback = function()
                edit_field(_("Max input size (characters)"), "max_input_chars",
                    _("Lower this for local models with small context windows"))
            end,
        },
    }
end

return Settings
