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
        assert.truthy(Main.VERSION:match("^%d+%.%d+%.%d+$"))
        assert.are.equal(dofile("kocatchup.koplugin/_meta.lua").version, Main.VERSION)
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

describe("main (rolling incremental recaps)", function()
    local Json = require("kocatchup_json")

    before_each(function()
        H.reset()
        Llm.transport = nil
    end)

    -- crengine ui where full extraction returns opts.fulltext and range
    -- extraction returns opts.deltas[from_xpointer]; page numbers per xpointer.
    local function make_roll_ui(opts)
        local doc = { info = { has_pages = false }, _at_start = false }
        function doc:getXPointer() return self._at_start and "xp_start" or "xp_cur" end
        function doc:gotoPos(_p) self._at_start = true end
        function doc:gotoXPointer(xp) self._at_start = (xp == "xp_start") end
        function doc:getTextFromXPointers(a, _b)
            if a == "xp_start" then return opts.fulltext end
            return opts.deltas and opts.deltas[a]
        end
        function doc:getProps() return { title = "The Book" } end
        function doc:getPageFromXPointer(xp)
            if xp == "xp_cur" then return opts.current_page or 50 end
            return opts.pages and opts.pages[xp]
        end
        function doc:getPageCount() return 100 end
        return {
            document = doc,
            toc = { getTocTitleByPage = function(_, page) return "Chapter " .. page end },
            doc_settings = H.make_doc_settings(),
            menu = { registerToMainMenu = function() end },
        }
    end

    local FULLTEXT = string.rep("EARLYBOOK ", 200)
    local DELTA = string.rep("newpages ", 60)

    local function roll_entry(overrides)
        local e = {
            recap = "old recap text", position = "xp:xp_old",
            xpointer = "xp_old", page = 40, percent = 0.4,
            model = "test-model", recap_length = "standard",
            roll_count = 2, rolled_chars = 5000, timestamp = 1,
        }
        for k, v in pairs(overrides or {}) do e[k] = v end
        return e
    end

    local function make_roll_plugin(entry, opts)
        configure_ollama()
        local ui = make_roll_ui(opts or { fulltext = FULLTEXT, deltas = { xp_old = DELTA } })
        if entry then ui.doc_settings:saveSetting("kocatchup", entry) end
        return make_plugin(ui), ui
    end

    local function capture_transport()
        local captured = {}
        Llm.transport = function(req)
            captured.req = req
            captured.user = Json.decode(req.body).messages[2].content
            return OPENAI_OK, 200
        end
        return captured
    end

    local function tap_update(plugin)
        plugin:onKoCatchupGenerate()
        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box, "expected the behind-state dialog")
        assert.are.equal("Update recap", box.ok_text)
        box.ok_callback()
    end

    it("rolls: sends previous recap + delta only, updates counters and position", function()
        local plugin, ui = make_roll_plugin(roll_entry())
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("old recap text", 1, true))
        assert.truthy(t.user:find("newpages", 1, true))
        assert.is_nil(t.user:find("EARLYBOOK", 1, true))
        local cached = ui.doc_settings.data.kocatchup
        assert.are.equal("xp:xp_cur", cached.position)
        assert.are.equal("xp_cur", cached.xpointer)
        assert.are.equal(50, cached.page)
        assert.are.equal(3, cached.roll_count)
        assert.are.equal(5000 + #DELTA, cached.rolled_chars)
    end)

    it("re-grounds at the roll-count limit: tail text plus previous recap, counters reset", function()
        local plugin, ui = make_roll_plugin(roll_entry({ roll_count = 10 }))
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
        assert.truthy(t.user:find("old recap text", 1, true))
        local cached = ui.doc_settings.data.kocatchup
        assert.are.equal(0, cached.roll_count)
        assert.are.equal(0, cached.rolled_chars)
    end)

    it("re-grounds when rolled volume exceeds the extraction window", function()
        local plugin = make_roll_plugin(roll_entry({ rolled_chars = 200000 }))
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
        assert.truthy(t.user:find("old recap text", 1, true))
    end)

    it("runs full generation when settings changed on the advanced path", function()
        local plugin = make_roll_plugin(roll_entry({ recap_length = "short" }))
        local t = capture_transport()

        plugin:onKoCatchupGenerate()
        local box = H.last_shown("ConfirmBox")
        box.ok_callback()

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
        assert.is_nil(t.user:find("old recap text", 1, true))
    end)

    it("runs full generation when the delta direction cannot be proven forward", function()
        -- Percent says behind, but the cached page is at/after the current page.
        local plugin = make_roll_plugin(roll_entry({ percent = 0.3, page = 60 }))
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
    end)

    it("rolls legacy v1 entries by parsing the identity key", function()
        local entry = roll_entry()
        entry.xpointer = nil
        entry.page = nil -- key "xp:xp_old" remains; page resolved via document
        local plugin = make_roll_plugin(entry, {
            fulltext = FULLTEXT, deltas = { xp_old = DELTA }, pages = { xp_old = 40 },
        })
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("old recap text", 1, true))
        assert.is_nil(t.user:find("EARLYBOOK", 1, true))
    end)

    it("manual update rolls any non-empty delta, however small", function()
        local plugin = make_roll_plugin(roll_entry(), {
            fulltext = FULLTEXT, deltas = { xp_old = "tiny" },
        })
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("tiny", 1, true))
        assert.is_nil(t.user:find("EARLYBOOK", 1, true))
    end)

    it("manual update with an empty range falls back to full generation", function()
        local plugin = make_roll_plugin(roll_entry(), {
            fulltext = FULLTEXT, deltas = { xp_old = "" },
        })
        local t = capture_transport()

        tap_update(plugin)

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
        for _, w in ipairs(H.shown) do
            if w.__widget == "InfoMessage" then
                assert.is_nil(w.text:find("Image-only", 1, true))
            end
        end
    end)

    it("exposes Regenerate-full-recap in Settings and forces full even on a cache hit", function()
        local plugin, ui = make_roll_plugin(roll_entry({
            position = "xp:xp_cur", xpointer = "xp_cur", page = 50, percent = 0.5,
        }))
        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local settings_items = menu_items.kocatchup.sub_item_table[2].sub_item_table
        local labels = {}
        for _, it in ipairs(settings_items) do labels[it.text] = true end
        assert.truthy(labels["Regenerate full recap"])
        local t = capture_transport()

        plugin:onRegenerateFullRecap()

        assert.truthy(t.user:find("EARLYBOOK", 1, true))
        assert.is_nil(t.user:find("old recap text", 1, true))
        assert.are.equal(0, ui.doc_settings.data.kocatchup.roll_count)
    end)

    it("escape hatch shows the spoiler guard before replacing an ahead recap", function()
        local plugin = make_roll_plugin(roll_entry({ percent = 0.8, position = "xp:later" }))
        Llm.transport = function() error("no generation before user confirms") end

        plugin:onRegenerateFullRecap()

        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        assert.truthy(box.text:find("later point", 1, true))
        local t = capture_transport()
        box.ok_callback()
        assert.truthy(t.user:find("EARLYBOOK", 1, true))
    end)

    it("escape hatch runs the standard entry checks", function()
        local ui = make_roll_ui({ fulltext = FULLTEXT })
        local plugin = make_plugin(ui) -- defaults: no API key
        plugin:onRegenerateFullRecap()
        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("No API key", 1, true))
    end)

    it("background pre-generation rolls silently when possible", function()
        local plugin, ui = make_roll_plugin(roll_entry())
        local cfg = Settings.load()
        cfg.auto_generate = true
        Settings.save(cfg)
        local t = capture_transport()

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.truthy(t.user:find("old recap text", 1, true))
        assert.is_nil(t.user:find("EARLYBOOK", 1, true))
        assert.are.equal(0, #H.shown)
        assert.are.equal(3, ui.doc_settings.data.kocatchup.roll_count)
    end)

    it("background pre-generation skips silently on a tiny delta", function()
        local plugin, ui = make_roll_plugin(roll_entry(), {
            fulltext = FULLTEXT, deltas = { xp_old = "tiny" },
        })
        local cfg = Settings.load()
        cfg.auto_generate = true
        Settings.save(cfg)
        Llm.transport = function() error("tiny background delta must not generate") end

        plugin:onReaderReady()
        H.fire_scheduled()

        assert.are.equal("old recap text", ui.doc_settings.data.kocatchup.recap)
        assert.are.equal(0, #H.shown)
    end)

    it("roll-path provider failure keeps the old cache entry and shows the typed message", function()
        local plugin, ui = make_roll_plugin(roll_entry())
        Llm.transport = function() return '{"error":"boom"}', 500 end

        tap_update(plugin)

        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("HTTP 500", 1, true))
        assert.are.equal("old recap text", ui.doc_settings.data.kocatchup.recap)
        assert.are.equal("xp:xp_old", ui.doc_settings.data.kocatchup.position)
    end)
end)

describe("main (auto-offer catch-up on reopen)", function()
    local Cache = require("kocatchup_cache")
    local NetworkMgr = require("ui/network/manager")

    before_each(function()
        H.reset()
        Llm.transport = nil
    end)

    local DAY = 86400

    local function offer_plugin(opts)
        opts = opts or {}
        configure_ollama()
        local cfg = Settings.load()
        cfg.auto_offer = true
        if opts.days then cfg.auto_offer_days = opts.days end
        if opts.auto_generate then cfg.auto_generate = true end
        Settings.save(cfg)
        local ui = make_ui(string.rep("story text ", 200), opts.page or 50)
        if opts.baseline then
            ui.doc_settings:saveSetting(Cache.LAST_READ_KEY, opts.baseline)
        end
        if opts.entry then
            ui.doc_settings:saveSetting("kocatchup", opts.entry)
        end
        return make_plugin(ui), ui
    end

    local function current_entry()
        return {
            recap = "cached recap", position = "xp:xp_cur",
            xpointer = "xp_cur", page = 50, percent = 0.5,
            model = "test-model", recap_length = "standard",
            roll_count = 0, rolled_chars = 0, timestamp = 1,
        }
    end

    it("offers after a qualifying break; accepting shows the cached recap offline", function()
        local plugin = offer_plugin({ baseline = os.time() - 5 * DAY, entry = current_entry() })
        Llm.transport = function() error("cached accept must not call the provider") end

        plugin:onReaderReady()
        assert.are.equal(1, #H.scheduled)
        H.fire_scheduled()

        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        assert.are.equal("Catch up", box.ok_text)
        assert.are.equal("Not now", box.cancel_text)
        box.ok_callback()
        local viewer = H.last_shown("TextViewer")
        assert.are.equal("cached recap", viewer.text)
        assert.are.equal(0, H.run_when_online_calls)
    end)

    it("stays quiet under the threshold, and respects the picker", function()
        local plugin = offer_plugin({ baseline = os.time() - 1 * DAY })
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))

        H.reset()
        plugin = offer_plugin({ days = 7, baseline = os.time() - 5 * DAY })
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))
    end)

    it("never offers without a baseline; a progressed session writes one", function()
        local plugin, ui = offer_plugin({})
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))

        plugin._session_start_key = "xp:somewhere_earlier"
        plugin:onCloseDocument()
        assert.is_not_nil(Cache.last_read(ui.doc_settings))
    end)

    it("setting off: no offer task, but progressed sessions still record", function()
        configure_ollama()
        local ui = make_ui(string.rep("story text ", 200), 50)
        local plugin = make_plugin(ui)
        plugin:onReaderReady()
        assert.are.equal(0, #H.scheduled)
        plugin._session_start_key = "xp:somewhere_earlier"
        plugin:onCloseDocument()
        assert.is_not_nil(Cache.last_read(ui.doc_settings))
    end)

    it("resume schedules the offer and suspend records progressed sessions", function()
        local plugin, ui = offer_plugin({ baseline = os.time() - 6 * DAY })
        plugin:onResume()
        assert.are.equal(1, #H.scheduled)
        H.fire_scheduled()
        assert.is_not_nil(H.last_shown("ConfirmBox"))

        plugin._session_start_key = "xp:somewhere_earlier"
        local before = Cache.last_read(ui.doc_settings)
        plugin:onSuspend()
        assert.truthy(Cache.last_read(ui.doc_settings) > before)
        assert.are.equal(0, #H.scheduled)
    end)

    it("a session with no progress preserves the old baseline", function()
        local plugin, ui = offer_plugin({ baseline = 123456 })
        plugin:onReaderReady() -- captures session-start key "xp:xp_cur"
        H.scheduled = {} -- ignore the offer task for this scenario
        plugin:onCloseDocument() -- position unchanged
        assert.are.equal(123456, Cache.last_read(ui.doc_settings))
    end)

    it("guards: bad config, too-early position, and clock jumps all mean silence", function()
        -- No API key (defaults) but auto_offer on:
        local cfg = Settings.load()
        cfg.auto_offer = true
        Settings.save(cfg)
        local ui = make_ui(string.rep("story text ", 200), 50)
        ui.doc_settings:saveSetting(Cache.LAST_READ_KEY, os.time() - 5 * DAY)
        local plugin = make_plugin(ui)
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))

        H.reset()
        plugin = offer_plugin({ baseline = os.time() - 5 * DAY, page = 1 })
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))

        H.reset()
        plugin = offer_plugin({ baseline = os.time() + 2 * DAY }) -- future baseline
        plugin:onReaderReady()
        H.fire_scheduled()
        assert.is_nil(H.last_shown("ConfirmBox"))
    end)

    it("accepting cancels the pending pregen task: exactly one generation", function()
        local plugin = offer_plugin({
            baseline = os.time() - 5 * DAY, auto_generate = true,
        })
        local transport_calls = 0
        Llm.transport = function()
            transport_calls = transport_calls + 1
            return OPENAI_OK, 200
        end

        plugin:onReaderReady()
        assert.are.equal(2, #H.scheduled)
        H.fire_scheduled(2) -- fire only the offer; pregen stays queued
        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        assert.are.equal(1, #H.scheduled, "pregen still queued while dialog is open")

        box.ok_callback()
        assert.are.equal(0, #H.scheduled, "accept must unschedule pregen")
        H.fire_scheduled()
        assert.are.equal(1, transport_calls)
    end)

    it("accept with no cache and declined Wi-Fi ends silently (documented trade-off)", function()
        local plugin, ui = offer_plugin({ baseline = os.time() - 5 * DAY })
        local orig = NetworkMgr.runWhenOnline
        NetworkMgr.runWhenOnline = function() end -- user declines the Wi-Fi prompt
        Llm.transport = function() error("no provider call without connectivity") end

        plugin:onReaderReady()
        H.fire_scheduled()
        local box = H.last_shown("ConfirmBox")
        H.shown = {}
        box.ok_callback()
        NetworkMgr.runWhenOnline = orig

        assert.are.equal(0, #H.shown)
        assert.is_nil(ui.doc_settings.data.kocatchup)
    end)
end)

describe("main (check for updates flow)", function()
    local Updater = require("kocatchup_updater")
    local Llm = require("kocatchup_llm")

    local orig_find_ca
    before_each(function()
        H.reset()
        Llm.transport = nil
        Updater.transport, Updater.hasher, Updater.archiver, Updater.fs = nil, nil, nil, nil
        orig_find_ca = Llm.find_ca_bundle
        Llm.find_ca_bundle = function() return "/data/ca-bundle.crt" end
    end)
    after_each(function()
        Llm.find_ca_bundle = orig_find_ca
    end)

    local RELEASE = '{"tag_name":"v9.9.9","assets":[{"name":"kocatchup-9.9.9.zip",'
        .. '"browser_download_url":"https://x/kocatchup-9.9.9.zip","digest":"sha256:hh"}]}'
    local SAME = '{"tag_name":"v' .. Main.VERSION .. '","assets":[{"name":"kocatchup-'
        .. Main.VERSION .. '.zip","browser_download_url":"u","digest":"sha256:hh"}]}'

    local function updater_plugin()
        local ui = make_ui("text", 50)
        local plugin = make_plugin(ui)
        plugin.path = "/mnt/plugins/kocatchup.koplugin"
        return plugin
    end

    it("adds 'Check for updates' as the last Settings item", function()
        local menu_items = {}
        updater_plugin():addToMainMenu(menu_items)
        local settings = menu_items.kocatchup.sub_item_table[2].sub_item_table
        assert.are.equal("Check for updates", settings[#settings].text)
    end)

    it("reports up to date without offering a download", function()
        Updater.transport = function() return SAME, 200 end
        local downloaded = false
        Updater.fs = { exists = function() downloaded = true return false end }
        updater_plugin():onCheckForUpdates()
        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("up to date", 1, true))
        assert.is_false(downloaded)
        assert.is_nil(H.last_shown("ConfirmBox"))
    end)

    it("offers an update, and confirming runs the pipeline then prompts restart", function()
        Updater.transport = function() return RELEASE, 200 end
        local ran = false
        -- After the check returns, installUpdate re-enters run(); stub run via seams:
        Updater.hasher = function() return "hh" end
        Updater.archiver = { extract = function() return true end }
        Updater.fs = {
            exists = function(p) return p:find("kocatchup.koplugin") ~= nil end,
            purge = function() end,
            rename = function() ran = true end,
            write = function() end,
            read = function() return 'version = "9.9.9"' end,
            loadcheck = function() return true end,
        }
        local plugin = updater_plugin()

        plugin:onCheckForUpdates()
        local box = H.last_shown("ConfirmBox")
        assert.is_not_nil(box)
        assert.are.equal("Update", box.ok_text)
        assert.truthy(box.text:find("9.9.9", 1, true))

        box.ok_callback()
        assert.is_true(ran, "pipeline renames should run on confirm")
        assert.truthy(#H.restart_prompts > 0, "should prompt for restart")
    end)

    it("aborts with tls_unavailable and no network when no CA bundle exists", function()
        Llm.find_ca_bundle = function() return nil end
        local touched = false
        Updater.transport = function() touched = true return "{}", 200 end
        updater_plugin():onCheckForUpdates()
        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("verified secure connection", 1, true))
        assert.is_false(touched, "no network request without a CA bundle")
    end)

    it("surfaces a download failure and never renames", function()
        Updater.transport = function() return RELEASE, 200 end
        local renamed = false
        Updater.hasher = function() return "hh" end
        Updater.archiver = { extract = function() return true end }
        Updater.fs = {
            exists = function() return true end,
            purge = function() end,
            rename = function() renamed = true end,
            write = function() end,
            read = function() return 'version = "9.9.9"' end,
            loadcheck = function() return true end,
        }
        local plugin = updater_plugin()
        plugin:onCheckForUpdates()
        -- swap the transport so the install-phase download fails
        Updater.transport = function() return nil, "timeout" end
        H.last_shown("ConfirmBox").ok_callback()
        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("didn't complete", 1, true))
        assert.is_false(renamed)
    end)

    it("maps a rate-limit response to a typed message", function()
        Updater.transport = function() return '{"message":"rate"}', 403 end
        updater_plugin():onCheckForUpdates()
        local info = H.last_shown("InfoMessage")
        assert.truthy(info.text:find("HTTP 403", 1, true))
    end)
end)
