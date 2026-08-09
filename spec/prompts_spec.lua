local H = require("helper")
local Prompts = require("kocatchup_prompts")

describe("kocatchup_prompts", function()
    before_each(function() H.reset() end)

    local meta = { title = "Dune", authors = "Frank Herbert", chapter = "Chapter 12" }

    it("includes book metadata and the extracted text", function()
        local p = Prompts.build(meta, "THE STORY TEXT", "standard")
        assert.truthy(p.user:find("Dune", 1, true))
        assert.truthy(p.user:find("Frank Herbert", 1, true))
        assert.truthy(p.user:find("Chapter 12", 1, true))
        assert.truthy(p.user:find("THE STORY TEXT", 1, true))
    end)

    it("instructs the model to never go beyond the provided text", function()
        local p = Prompts.build(meta, "text", "standard")
        assert.truthy(p.system:find("Never reveal", 1, true))
        assert.truthy(p.system:find("beyond the provided text", 1, true))
        assert.truthy(p.system:find("same language", 1, true))
    end)

    it("varies target length by preset", function()
        local short = Prompts.build(meta, "text", "short")
        local standard = Prompts.build(meta, "text", "standard")
        local detailed = Prompts.build(meta, "text", "detailed")
        assert.truthy(short.system:find("150", 1, true))
        assert.truthy(standard.system:find("400", 1, true))
        assert.truthy(detailed.system:find("800", 1, true))
    end)

    it("falls back to standard length for unknown presets", function()
        local p = Prompts.build(meta, "text", "gigantic")
        assert.truthy(p.system:find("400", 1, true))
    end)

    it("degrades gracefully when metadata is missing", function()
        local p = Prompts.build(nil, "just the text", "standard")
        assert.truthy(p.user:find("Text read so far", 1, true))
        assert.truthy(p.user:find("just the text", 1, true))
        assert.is_nil(p.user:find("Book:", 1, true))
    end)
end)
