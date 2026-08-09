local H = require("helper")
local Main = require("main")
local Llm = require("kocatchup_llm")
local Settings = require("kocatchup_settings")
local Trapper = require("ui/trapper")

-- crengine-style ui with a doc_settings sidecar, positioned mid-book
local function make_ui(fulltext, current_page)
    local doc = { info = { has_pages = false }, _at_start = false }
    function doc:getXPointer()
        return self._at_start and "xp_start" or "xp_cur"
    end
    function doc:gotoPos(_p) self._at_start = true end
    function doc:gotoXPointer(xp) self._at_start = (xp == "xp_start") end
    function doc:getTextFromXPointers(_a, _b) return fulltext end
    function doc:getProps() return { title = "The Book", authors = "A. Author" } end
    function doc:getPageFromXPointer(_xp) return current_page end
    function doc:getPageCount() return 100 end
    return {
        document = doc,
        toc = { getTocTitleByPage = function(_, page) return "Chapter " .. page end },
        doc_settings = H.make_doc_settings(),
        menu = { registerToMainMenu = function() end },
    }
end

local function make_plugin(ui)
    return setmetatable({ ui = ui }, { __index = Main })
end

local function configure_ollama()
    local cfg = Settings.load()
    cfg.provider = "openai"
    cfg.base_url = "http://localhost:11434/v1"
    cfg.model = "test-model"
    cfg.api_key = ""
    Settings.save(cfg)
end

local OPENAI_OK = '{"choices":[{"message":{"content":"A fine recap"}}]}'

describe("main (kocatchup plugin)", function()
    before_each(function()
        H.reset()
        Llm.transport = nil
    end)

    it("loads under mocks with the expected identity", function()
        assert.are.equal("kocatchup", Main.name)
        assert.is_true(Main.is_doc_only)
    end)

    it("produces a distinct message for every error type", function()
        local types = { "no_api_key", "no_text", "too_short", "timeout",
            "bad_response", "tls_error" }
        local seen = {}
        for _, t in ipairs(types) do
            local msg = Main.error_message(t)
            assert.is_not_nil(msg)
            assert.is_nil(seen[msg], "duplicate message for " .. t)
            seen[msg] = t
        end
        assert.truthy(Main.error_message("http_error", 401):find("401", 1, true))
    end)

    it("registers a submenu with generate and settings entries", function()
        local plugin = make_plugin(make_ui("", 50))
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local item = menu_items.kocatchup
        assert.are.equal("KO Catchup", item.text)
        assert.are.equal("Generate recap", item.sub_item_table[1].text)
        assert.are.equal("Settings", item.sub_item_table[2].text)
        assert.truthy(#item.sub_item_table[2].sub_item_table > 0)
    end)

    it("generates a recap end-to-end, shows it, and caches it", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        local requested_url
        Llm.transport = function(req)
            requested_url = req.url
            return OPENAI_OK, 200
        end

        plugin:onKoCatchupGenerate()

        assert.are.equal("http://localhost:11434/v1/chat/completions", requested_url)
        local viewer = H.last_shown("TextViewer")
        assert.is_not_nil(viewer)
        assert.are.equal("A fine recap", viewer.text)
        assert.truthy(viewer.title:find("The Book", 1, true))
        local cached = ui.doc_settings.data.kocatchup
        assert.are.equal("A fine recap", cached.recap)
        assert.are.equal("xp:xp_cur", cached.position)
        assert.are.equal("test-model", cached.model)
    end)

    it("serves a same-position cache hit without any provider call", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        Llm.transport = function() return OPENAI_OK, 200 end
        plugin:onKoCatchupGenerate()
        local network_calls = H.run_when_online_calls

        H.shown = {}
        Llm.transport = function() error("provider must not be called on cache hit") end
        plugin:onKoCatchupGenerate()

        local viewer = H.last_shown("TextViewer")
        assert.is_not_nil(viewer)
        assert.are.equal("A fine recap", viewer.text)
        assert.are.equal(network_calls, H.run_when_online_calls)
    end)

    it("warns instead of showing a cached recap from a later position", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        -- Cache written at 80%; reader is now at 50% (jumped back).
        ui.doc_settings:saveSetting("kocatchup", {
            recap = "future recap", position = "xp:later", percent = 0.8,
            model = "test-model", recap_length = "standard", timestamp = 1,
        })
        local plugin = make_plugin(ui)
        Llm.transport = function() error("no generation before user confirms") end

        plugin:onKoCatchupGenerate()

        assert.is_nil(H.last_shown("TextViewer"))
        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        assert.truthy(box.text:find("spoil", 1, true))

        -- Confirming generates a fresh recap for the current position.
        Llm.transport = function() return OPENAI_OK, 200 end
        box.ok_callback()
        local viewer = H.last_shown("TextViewer")
        assert.are.equal("A fine recap", viewer.text)
        assert.are.equal("xp:xp_cur", ui.doc_settings.data.kocatchup.position)
    end)

    it("offers saved-or-regenerate when the reader has advanced", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        ui.doc_settings:saveSetting("kocatchup", {
            recap = "older recap", position = "xp:earlier", percent = 0.2,
            model = "test-model", recap_length = "standard", timestamp = 1,
        })
        local plugin = make_plugin(ui)

        plugin:onKoCatchupGenerate()

        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        box.cancel_callback()
        local viewer = H.last_shown("TextViewer")
        assert.are.equal("older recap", viewer.text)
    end)

    it("shows the no-API-key message before any network prompt", function()
        -- Defaults: openai provider, default endpoint, no key.
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)

        plugin:onKoCatchupGenerate()

        local info = H.last_shown("InfoMessage")
        assert.is_not_nil(info)
        assert.truthy(info.text:find("No API key", 1, true))
        assert.are.equal(0, H.run_when_online_calls)
    end)

    it("shows the too-early message without extracting or connecting", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 1) -- page 1 of 100
        local plugin = make_plugin(ui)

        plugin:onKoCatchupGenerate()

        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("too early", 1, true))
        assert.are.equal(0, H.run_when_online_calls)
    end)

    it("shows a cancellation message when the user dismisses generation", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        local original = Trapper.dismissableRunInSubprocess
        Trapper.dismissableRunInSubprocess = function() return false end

        plugin:onKoCatchupGenerate()
        Trapper.dismissableRunInSubprocess = original

        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("cancelled", 1, true))
        assert.is_nil(H.last_shown("TextViewer"))
    end)

    it("surfaces provider HTTP errors with the status code", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        Llm.transport = function() return '{"error":"boom"}', 500 end

        plugin:onKoCatchupGenerate()

        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("HTTP 500", 1, true))
        assert.is_nil(ui.doc_settings.data.kocatchup)
    end)
end)

describe("main (background pre-generation)", function()
    before_each(function()
        H.reset()
        Llm.transport = nil
    end)

    local function enable_pregen()
        configure_ollama()
        local cfg = Settings.load()
        cfg.auto_generate = true
        Settings.save(cfg)
    end

    it("schedules nothing when the setting is off (default)", function()
        configure_ollama()
        local plugin = make_plugin(make_ui(string.rep("story text ", 200), 50))
        plugin:onReaderReady()
        assert.are.equal(0, #H.scheduled)
    end)

    it("silently generates and caches on a stale cache, with no UI", function()
        enable_pregen()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        Llm.transport = function() return OPENAI_OK, 200 end

        plugin:onReaderReady()
        assert.are.equal(1, #H.scheduled)
        H.fire_scheduled()

        assert.are.equal("A fine recap", ui.doc_settings.data.kocatchup.recap)
        assert.are.equal(0, #H.shown, "background generation must show no widgets")
    end)

    it("skips silently when offline and never prompts for Wi-Fi", function()
        enable_pregen()
        H.network_online = false
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        Llm.transport = function() error("no network call expected offline") end

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.is_nil(ui.doc_settings.data.kocatchup)
        assert.are.equal(0, H.run_when_online_calls)
        assert.are.equal(0, #H.shown)
    end)

    it("does nothing on a same-position cache hit", function()
        enable_pregen()
        local ui = make_ui(string.rep("story text ", 200), 50)
        ui.doc_settings:saveSetting("kocatchup", {
            recap = "existing", position = "xp:xp_cur", percent = 0.5,
            model = "test-model", recap_length = "standard", timestamp = 1,
        })
        local plugin = make_plugin(ui)
        Llm.transport = function() error("no call expected on cache hit") end

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.are.equal("existing", ui.doc_settings.data.kocatchup.recap)
    end)

    it("never overwrites a later-position recap after a backward jump", function()
        enable_pregen()
        local ui = make_ui(string.rep("story text ", 200), 50)
        ui.doc_settings:saveSetting("kocatchup", {
            recap = "future recap", position = "xp:later", percent = 0.8,
            model = "test-model", recap_length = "standard", timestamp = 1,
        })
        local plugin = make_plugin(ui)
        Llm.transport = function() error("no call expected for ahead cache") end

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.are.equal("future recap", ui.doc_settings.data.kocatchup.recap)
        assert.are.equal(0, #H.shown)
    end)

    it("stays silent on provider errors and leaves the cache unchanged", function()
        enable_pregen()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        Llm.transport = function() return '{"error":"boom"}', 500 end

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.is_nil(ui.doc_settings.data.kocatchup)
        assert.are.equal(0, #H.shown, "errors must not surface UI in background mode")
    end)

    it("unschedules the task when the document closes first", function()
        enable_pregen()
        local plugin = make_plugin(make_ui(string.rep("story text ", 200), 50))

        plugin:onReaderReady()
        assert.are.equal(1, #H.scheduled)
        plugin:onCloseDocument()
        assert.are.equal(0, #H.scheduled)
    end)
end)
