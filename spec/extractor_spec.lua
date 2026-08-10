local H = require("helper")
local Extractor = require("kocatchup_extractor")

-- crengine-style document/ui mock
local function make_cre_ui(fulltext)
    local doc = { info = { has_pages = false }, _at_start = false }
    function doc:getXPointer()
        return self._at_start and "xp_start" or "xp_cur"
    end
    function doc:gotoPos(_pos) self._at_start = true end
    function doc:gotoXPointer(xp) self._at_start = (xp == "xp_start") end
    function doc:getTextFromXPointers(a, b)
        assert(a == "xp_start", "expected extraction from document start")
        assert(b == "xp_cur", "expected extraction to current position")
        return fulltext
    end
    function doc:getProps() return { title = "The Book", authors = "The Author" } end
    function doc:getPageFromXPointer(_xp) return 42 end
    function doc:getPageCount() return 100 end
    local ui = {
        document = doc,
        toc = { getTocTitleByPage = function(_, page) return "Chapter " .. page end },
    }
    return ui, doc
end

-- page-based document/ui mock; page_text_fn(page) -> getPageText return value
local function make_paged_ui(current_page, page_text_fn)
    local requested = {}
    local doc = { info = { has_pages = true }, requested = requested }
    function doc:getPageText(page)
        table.insert(requested, page)
        return page_text_fn(page)
    end
    function doc:getProps() return { title = "Scanned Book" } end
    function doc:getPageCount() return current_page + 10 end
    local ui = {
        document = doc,
        view = { state = { page = current_page } },
        toc = { getTocTitleByPage = function(_, page) return "Chapter " .. page end },
    }
    return ui, doc
end

describe("kocatchup_extractor", function()
    before_each(function() H.reset() end)

    it("returns the text between start and current xpointers with metadata", function()
        local text = string.rep("a", 1000)
        local ui = make_cre_ui(text)
        local result, err = Extractor.extract(ui, {})
        assert.is_nil(err)
        assert.are.equal(text, result.text)
        assert.are.equal("The Book", result.metadata.title)
        assert.are.equal("The Author", result.metadata.authors)
        assert.are.equal("Chapter 42", result.metadata.chapter)
    end)

    it("restores the reading position after the xpointer round-trip", function()
        local ui, doc = make_cre_ui(string.rep("a", 1000))
        Extractor.extract(ui, {})
        assert.is_false(doc._at_start)
        assert.are.equal("xp_cur", doc:getXPointer())
    end)

    it("keeps the tail (most recent text) when truncating", function()
        local text = string.rep("x", 500) .. string.rep("y", 600)
        local ui = make_cre_ui(text)
        local result = Extractor.extract(ui, { max_input_chars = 600 })
        assert.are.equal(600, #result.text)
        assert.is_nil(result.text:find("x"))
    end)

    it("starts truncated text on a valid UTF-8 boundary", function()
        -- 400 copies of é (2 bytes each). A 601-byte tail starts mid-character;
        -- the leading continuation byte must be stripped.
        local text = string.rep("\195\169", 400)
        local ui = make_cre_ui(text)
        local result = Extractor.extract(ui, { max_input_chars = 601 })
        assert.are.equal(600, #result.text)
        assert.are.equal(0xC3, result.text:byte(1))
    end)

    it("fails with too_short at the very start of a book", function()
        local ui = make_cre_ui("short text")
        local result, err = Extractor.extract(ui, {})
        assert.is_nil(result)
        assert.are.equal("too_short", err)
    end)

    it("fails with no_text when the document yields nothing", function()
        local ui = make_cre_ui("")
        local result, err = Extractor.extract(ui, {})
        assert.is_nil(result)
        assert.are.equal("no_text", err)
    end)

    it("reads a bounded page lookback ending at the current page", function()
        local ui, doc = make_paged_ui(300, function(page)
            return { { { word = "word" .. page } } }
        end)
        local result, err = Extractor.extract(ui, {})
        assert.is_nil(err)
        assert.are.equal(50, doc.requested[1])
        assert.are.equal(300, doc.requested[#doc.requested])
        assert.truthy(result.text:find("word50", 1, true))
        assert.truthy(result.text:find("word300", 1, true))
    end)

    it("joins word spans with spaces", function()
        local ui = make_paged_ui(300, function(page)
            return { { { word = "alpha" .. page }, { word = "beta" .. page } } }
        end)
        local result = Extractor.extract(ui, {})
        assert.truthy(result.text:find("alpha77 beta77", 1, true))
    end)

    it("fails with no_text for image-only page documents", function()
        local ui = make_paged_ui(300, function() return nil end)
        local result, err = Extractor.extract(ui, {})
        assert.is_nil(result)
        assert.are.equal("no_text", err)
    end)
end)

describe("kocatchup_extractor.extract_delta", function()
    before_each(function() H.reset() end)

    local function make_delta_ui(deltas)
        local doc = { info = { has_pages = false } }
        function doc:getXPointer() return "xp_cur" end
        function doc:getTextFromXPointers(a, b)
            assert(b == "xp_cur", "delta must end at the current position")
            return deltas[a]
        end
        function doc:getProps() return { title = "The Book" } end
        function doc:getPageFromXPointer(_xp) return 60 end
        function doc:getPageCount() return 100 end
        return {
            document = doc,
            toc = { getTocTitleByPage = function(_, page) return "Chapter " .. page end },
        }
    end

    it("extracts only the range between the stored and current xpointers", function()
        local ui = make_delta_ui({ xp_old = string.rep("new words ", 50) })
        local result, err = Extractor.extract_delta(ui, { xpointer = "xp_old" }, {})
        assert.is_nil(err)
        assert.truthy(result.text:find("new words", 1, true))
        assert.are.equal("Chapter 60", result.metadata.chapter)
    end)

    it("reads only pages after the stored page for paged documents", function()
        local ui, doc = make_paged_ui(60, function(page)
            return { { { word = "word" .. page .. string.rep("x", 20) } } }
        end)
        local result, err = Extractor.extract_delta(ui, { page = 40 }, {})
        assert.is_nil(err)
        assert.are.equal(41, doc.requested[1])
        assert.are.equal(60, doc.requested[#doc.requested])
        assert.is_nil(result.text:find("word40", 1, true))
        assert.truthy(result.text:find("word41", 1, true))
    end)

    it("honors the default minimum but rolls any non-empty delta at minimum 0", function()
        local ui = make_delta_ui({ xp_old = "tiny" })
        local result, err = Extractor.extract_delta(ui, { xpointer = "xp_old" }, {})
        assert.is_nil(result)
        assert.are.equal("too_short", err)
        local ok = Extractor.extract_delta(ui, { xpointer = "xp_old" }, { min_delta_chars = 0 })
        assert.are.equal("tiny", ok.text)
    end)

    it("returns no_text for an empty range regardless of minimum", function()
        local ui = make_delta_ui({ xp_old = "" })
        local result, err = Extractor.extract_delta(ui, { xpointer = "xp_old" }, { min_delta_chars = 0 })
        assert.is_nil(result)
        assert.are.equal("no_text", err)
    end)

    it("tail-truncates oversized deltas on a UTF-8 boundary", function()
        local ui = make_delta_ui({ xp_old = string.rep("\195\169", 400) })
        local result = Extractor.extract_delta(ui, { xpointer = "xp_old" },
            { max_input_chars = 601 })
        assert.are.equal(600, #result.text)
        assert.are.equal(0xC3, result.text:byte(1))
    end)
end)
