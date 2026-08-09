-- Loader-level smoke check (DoD emulator-smoke approximation): drives
-- KOReader's REAL frontend/pluginloader.lua (vendored in _koreader/) against
-- an install-layout copy of the plugin in ./plugins/, verifying:
--   1. the plugin is discovered and loaded by the real loader
--   2. _meta.lua merges (fullname/description) with no deprecation warnings
--   3. it appears in the real plugin-manager menu ("User plugins", checked)
--   4. a reader-context instance initializes and registers its main menu
--   5. it carries is_doc_only (the flag FileManager filters on)
--   6. disabling it via settings routes it to disabled_plugins
--
-- Usage: luajit spec/smoke_pluginloader.lua   (run from the repo root, with
--        the plugin copied to ./plugins/kocatchup.koplugin)
package.path = "./spec/?.lua;" .. package.path
require("helper") -- KOReader widget/service mocks via package.preload

-- Extra shims pluginloader.lua needs beyond the spec helper --------------

package.preload["ui/widget/buttondialog"] = function()
    local W = { __widget = "ButtonDialog" }
    function W:new(o) o = o or {}; setmetatable(o, { __index = self }); return o end
    return W
end

package.preload["dbg"] = function()
    return { is_on = false }
end

package.preload["ffi/util"] = function()
    return { purgeDir = function() return true end }
end

-- Pure-Lua stand-in for KOReader's lfs (dir listing + mode attributes).
package.preload["libs/libkoreader-lfs"] = function()
    local lfs = {}
    local function winpath(p) return (p:gsub("/", "\\")) end
    function lfs.dir(path)
        local pipe = io.popen('cmd /c dir /b "' .. winpath(path) .. '" 2>nul')
        local entries = { ".", ".." }
        if pipe then
            for line in pipe:lines() do entries[#entries + 1] = line end
            pipe:close()
        end
        local i = 0
        return function()
            i = i + 1
            return entries[i]
        end
    end
    function lfs.attributes(path, what)
        local wp = winpath(path)
        local pipe = io.popen('cmd /c if exist "' .. wp .. '\\" (echo D) else if exist "' .. wp .. '" (echo F)')
        local out = pipe and pipe:read("*a") or ""
        if pipe then pipe:close() end
        local mode
        if out:find("D") then mode = "directory"
        elseif out:find("F") then mode = "file" end
        if what == "mode" then return mode end
        return mode and { mode = mode } or nil
    end
    return lfs
end

-- Global settings store the real loader reads.
G_reader_settings = {
    data = {},
    readSetting = function(self, k, default)
        if self.data[k] == nil and default ~= nil then self.data[k] = default end
        return self.data[k]
    end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    isTrue = function(self, k) return self.data[k] == true end,
    nilOrFalse = function(self, k) return self.data[k] == nil or self.data[k] == false end,
    delSetting = function(self, k) self.data[k] = nil end,
    has = function(self, k) return self.data[k] ~= nil end,
}

local checks, failed = 0, 0
local function check(cond, label)
    checks = checks + 1
    if cond then
        print("  PASS " .. label)
    else
        failed = failed + 1
        print("  FAIL " .. label)
    end
end

-- 1-3: discovery, load, plugin-manager listing ---------------------------

print("[1] Real PluginLoader discovery and load")
local PluginLoader = dofile("_koreader/pluginloader.lua")
local enabled, disabled = PluginLoader:loadPlugins()

local plugin
for _, p in ipairs(enabled) do
    if p.name == "kocatchup" then plugin = p end
end
check(plugin ~= nil, "kocatchup discovered in ./plugins and loaded (enabled)")
check(#disabled == 0, "no plugins wrongly disabled")
check(plugin and plugin.fullname == "KO Catchup", "_meta.lua fullname merged: " .. tostring(plugin and plugin.fullname))
check(plugin and type(plugin.description) == "string" and #plugin.description > 0, "_meta.lua description merged")
check(plugin and plugin.is_doc_only == true, "is_doc_only flag present (FileManager filters on this)")

print("[2] Plugin-manager menu listing")
local manager_menu = PluginLoader:genPluginManagerSubItem()
local user_section
for _, section in ipairs(manager_menu) do
    if section.text == "User plugins" then user_section = section end
end
local listed, listed_checked = false, false
if user_section then
    for _, item in ipairs(user_section.sub_item_table) do
        if item.text == "KO Catchup" then
            listed = true
            listed_checked = item.checked_func()
        end
    end
end
check(listed, "listed under User plugins as 'KO Catchup'")
check(listed_checked, "shown as enabled in the plugin manager")

print("[3] Reader-context instance (menu registration)")
local registered
local fake_reader_ui
fake_reader_ui = {
    menu = { registerToMainMenu = function(_, widget) registered = widget end },
    document = { info = { has_pages = false } },
}
fake_reader_ui.menu.registerToMainMenu = function(_, widget) registered = widget end
local ok, instance = PluginLoader:createPluginInstance(plugin, { ui = fake_reader_ui })
check(ok and instance ~= nil, "createPluginInstance succeeds in reader context")
check(registered == instance, "instance registered itself into the reader main menu")
local menu_items = {}
instance:addToMainMenu(menu_items)
check(menu_items.kocatchup ~= nil and menu_items.kocatchup.text == "KO Catchup",
    "main menu entry 'KO Catchup' present")
check(menu_items.kocatchup.sub_item_table[1].text == "Generate recap",
    "'Generate recap' submenu entry present")

print("[4] Disable path")
local PluginLoader2 = dofile("_koreader/pluginloader.lua")
G_reader_settings:saveSetting("plugins_disabled", { kocatchup = true })
local enabled2, disabled2 = PluginLoader2:loadPlugins()
local still_enabled = false
for _, p in ipairs(enabled2) do
    if p.name == "kocatchup" then still_enabled = true end
end
local now_disabled = false
for _, p in ipairs(disabled2) do
    if p.name == "kocatchup" then now_disabled = true end
end
check(not still_enabled, "disabled via plugins_disabled: not in enabled list")
check(now_disabled, "disabled via plugins_disabled: present in disabled list")

print(string.format("\n%d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
