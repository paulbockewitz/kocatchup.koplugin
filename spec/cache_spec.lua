local H = require("helper")
local Cache = require("kocatchup_cache")

local cfg = { model = "gpt-4o-mini", recap_length = "standard" }

local function entry_at(percent, overrides)
    local e = {
        recap = "the recap",
        position = "xp:abc",
        percent = percent,
        model = cfg.model,
        recap_length = cfg.recap_length,
        timestamp = 1000,
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

describe("kocatchup_cache", function()
    before_each(function() H.reset() end)

    it("round-trips an entry through DocSettings", function()
        local ds = H.make_doc_settings()
        local entry = entry_at(0.5)
        Cache.write(ds, entry)
        assert.truthy(ds.flushed > 0)
        local read = Cache.read(ds)
        assert.are.same(entry, read)
    end)

    it("treats corrupt or missing entries as a miss", function()
        local ds = H.make_doc_settings()
        assert.is_nil(Cache.read(ds))
        ds:saveSetting(Cache.KEY, "not a table")
        assert.is_nil(Cache.read(ds))
        ds:saveSetting(Cache.KEY, { recap = "", position = "xp:abc" })
        assert.is_nil(Cache.read(ds))
        ds:saveSetting(Cache.KEY, { recap = "ok" }) -- no position
        assert.is_nil(Cache.read(ds))
    end)

    it("reports hit for same position and same settings", function()
        local state = Cache.compare(entry_at(0.5), { key = "xp:abc", percent = 0.5 }, cfg)
        assert.are.equal("hit", state)
    end)

    it("reports settings_changed when model or length changed at same position", function()
        local state = Cache.compare(entry_at(0.5, { model = "old-model" }),
            { key = "xp:abc", percent = 0.5 }, cfg)
        assert.are.equal("settings_changed", state)
        state = Cache.compare(entry_at(0.5, { recap_length = "short" }),
            { key = "xp:abc", percent = 0.5 }, cfg)
        assert.are.equal("settings_changed", state)
    end)

    it("reports ahead when the cache covers a later point than the reader", function()
        -- Reader jumped back to re-read: cached recap would spoil.
        local state = Cache.compare(entry_at(0.8), { key = "xp:other", percent = 0.5 }, cfg)
        assert.are.equal("ahead", state)
    end)

    it("reports behind when the reader has advanced past the cache", function()
        local state = Cache.compare(entry_at(0.3), { key = "xp:other", percent = 0.5 }, cfg)
        assert.are.equal("behind", state)
    end)

    it("reports miss when there is no entry", function()
        assert.are.equal("miss", Cache.compare(nil, { key = "xp:abc", percent = 0.5 }, cfg))
    end)
end)

describe("kocatchup_cache schema v2", function()
    before_each(function() H.reset() end)

    it("round-trips raw position fields and drift counters", function()
        local ds = H.make_doc_settings()
        local entry = entry_at(0.5, { xpointer = "xp_raw", page = 42,
            roll_count = 3, rolled_chars = 12000 })
        Cache.write(ds, entry)
        local read = Cache.read(ds)
        assert.are.equal("xp_raw", read.xpointer)
        assert.are.equal(42, read.page)
        local rolls, chars = Cache.counters(read)
        assert.are.equal(3, rolls)
        assert.are.equal(12000, chars)
    end)

    it("defaults counters to 0 for v1 entries and nil entries", function()
        local rolls, chars = Cache.counters(entry_at(0.5))
        assert.are.equal(0, rolls)
        assert.are.equal(0, chars)
        rolls, chars = Cache.counters(nil)
        assert.are.equal(0, rolls)
        assert.are.equal(0, chars)
    end)

    it("prefers explicit raw fields for the rollable position", function()
        local from = Cache.rollable_position(entry_at(0.5, { xpointer = "xp_raw" }))
        assert.are.equal("xp_raw", from.xpointer)
        from = Cache.rollable_position(entry_at(0.5, { page = 7, position = "page:7" }))
        assert.are.equal(7, from.page)
    end)

    it("recovers legacy v1 entries by parsing the identity key", function()
        local from = Cache.rollable_position(entry_at(0.5)) -- position = "xp:abc"
        assert.are.equal("abc", from.xpointer)
        from = Cache.rollable_position(entry_at(0.5, { position = "page:33" }))
        assert.are.equal(33, from.page)
        assert.is_nil(Cache.rollable_position(entry_at(0.5, { position = "garbage" })))
        assert.is_nil(Cache.rollable_position(nil))
    end)
end)
