-- package.preload mocks for the KOReader modules the plugin requires, so
-- specs run on plain LuaJIT (or under busted) without a KOReader checkout.
local H = {
    shown = {},          -- widgets passed to UIManager:show, in order
    trapper_infos = {},  -- Trapper:info messages
    settings_stores = {},-- LuaSettings backing stores, keyed by path
    scheduled = {},      -- { delay_s, fn } pairs from UIManager:scheduleIn
    restart_prompts = {},-- messages passed to UIManager:askForRestart
    run_when_online_calls = 0,
    network_online = true,
}

function H.reset()
    H.shown = {}
    H.trapper_infos = {}
    H.settings_stores = {}
    H.scheduled = {}
    H.restart_prompts = {}
    H.run_when_online_calls = 0
    H.network_online = true
end

-- Run scheduled callbacks as if their timers fired. With max_delay_s, fires
-- only tasks scheduled at or under that delay, leaving later ones queued
-- (lets tests fire a 2s task while a 20s task stays pending).
function H.fire_scheduled(max_delay_s)
    local tasks = H.scheduled
    H.scheduled = {}
    for _, t in ipairs(tasks) do
        if max_delay_s and t[1] > max_delay_s then
            table.insert(H.scheduled, t)
        else
            t[2]()
        end
    end
end

-- Minimal KOReader-style widget class: :extend for subclassing, :new for
-- instances (calls init).
local function widget_class(name)
    local W = { __widget = name }
    function W:extend(o)
        o = o or {}
        setmetatable(o, { __index = self })
        return o
    end
    function W:new(o)
        o = o or {}
        o.__widget = name
        setmetatable(o, { __index = self })
        if o.init then o:init() end
        return o
    end
    return W
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return widget_class("WidgetContainer")
end

package.preload["ui/widget/infomessage"] = function()
    return widget_class("InfoMessage")
end

package.preload["ui/widget/confirmbox"] = function()
    return widget_class("ConfirmBox")
end

package.preload["ui/widget/textviewer"] = function()
    return widget_class("TextViewer")
end

package.preload["ui/widget/inputdialog"] = function()
    local W = widget_class("InputDialog")
    function W:getInputText() return self.input end
    function W:onShowKeyboard() end
    return W
end

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) table.insert(H.shown, w) end,
        close = function() end,
        nextTick = function(_, fn) fn() end,
        scheduleIn = function(_, delay_s, fn)
            table.insert(H.scheduled, { delay_s, fn })
        end,
        unschedule = function(_, fn)
            for i = #H.scheduled, 1, -1 do
                if H.scheduled[i][2] == fn then table.remove(H.scheduled, i) end
            end
        end,
        askForRestart = function(_, msg) table.insert(H.restart_prompts, msg) end,
    }
end

package.preload["ui/network/manager"] = function()
    return {
        runWhenOnline = function(_, cb)
            H.run_when_online_calls = H.run_when_online_calls + 1
            cb()
        end,
        isOnline = function() return H.network_online end,
    }
end

package.preload["ui/trapper"] = function()
    return {
        wrap = function(_, fn) return fn() end,
        info = function(_, msg) table.insert(H.trapper_infos, msg) end,
        clear = function() end,
        dismissableRunInSubprocess = function(_, fn, _widget)
            return true, fn()
        end,
    }
end

package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return "./_test_settings" end,
        getDataDir = function() return "." end,
    }
end

package.preload["luasettings"] = function()
    local LuaSettings = {}
    function LuaSettings:open(path)
        local data = H.settings_stores[path] or {}
        H.settings_stores[path] = data
        return {
            readSetting = function(_, k) return data[k] end,
            saveSetting = function(_, k, v) data[k] = v end,
            flush = function() end,
        }
    end
    return LuaSettings
end

-- In-memory DocSettings stand-in for cache specs (passed in, not required).
function H.make_doc_settings()
    local data = {}
    return {
        data = data,
        flushed = 0,
        readSetting = function(_, k) return data[k] end,
        saveSetting = function(_, k, v) data[k] = v end,
        flush = function(self) self.flushed = self.flushed + 1 end,
    }
end

-- Last widget of a given mock type shown via UIManager.
function H.last_shown(widget_name)
    for i = #H.shown, 1, -1 do
        if H.shown[i].__widget == widget_name then
            return H.shown[i]
        end
    end
    return nil
end

return H
