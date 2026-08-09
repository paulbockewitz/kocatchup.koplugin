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
