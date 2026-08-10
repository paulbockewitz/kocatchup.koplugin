-- Per-book recap cache, stored in the book's DocSettings sidecar under a
-- plugin-namespaced key. An entry records the recap, the position it covers
-- (opaque key + percent), and the settings it was generated with.
local Cache = {
    KEY = "kocatchup",
    EPS = 0.001,
}

-- Returns the cached entry table, or nil when absent/corrupt.
function Cache.read(doc_settings)
    if not doc_settings then return nil end
    local ok, entry = pcall(function() return doc_settings:readSetting(Cache.KEY) end)
    if not ok or type(entry) ~= "table" then return nil end
    if type(entry.recap) ~= "string" or entry.recap == "" or entry.position == nil then
        return nil
    end
    return entry
end

function Cache.write(doc_settings, entry)
    if not doc_settings then return end
    pcall(function() doc_settings:saveSetting(Cache.KEY, entry) end)
    pcall(function()
        if doc_settings.flush then doc_settings:flush() end
    end)
end

-- Compares a cached entry against the current position and settings.
-- Returns one of:
--   "miss"             no usable cache entry
--   "hit"              same position, same model/length: show instantly
--   "settings_changed" same position but model/recap length changed
--   "ahead"            cache covers a LATER point than the reader is at now
--                      (spoiler risk: never show by default)
--   "behind"           reader has advanced past the cached position
function Cache.compare(entry, pos, cfg)
    if not entry then return "miss" end
    local settings_same = entry.model == cfg.model
        and entry.recap_length == cfg.recap_length
    if entry.position == pos.key then
        return settings_same and "hit" or "settings_changed"
    end
    local ep, cp = tonumber(entry.percent), tonumber(pos.percent)
    if ep and cp and ep > cp + Cache.EPS then
        return "ahead"
    end
    return "behind"
end

-- Returns the raw position usable as a delta-extraction start point:
-- { xpointer = ... } or { page = ... }, or nil when unrecoverable.
-- Prefers explicit fields (schema v2); falls back to parsing the identity
-- key so entries written by 0.2.0 remain rollable.
function Cache.rollable_position(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.xpointer) == "string" and entry.xpointer ~= "" then
        return { xpointer = entry.xpointer }
    end
    if tonumber(entry.page) then
        return { page = tonumber(entry.page) }
    end
    if type(entry.position) == "string" then
        local xp = entry.position:match("^xp:(.+)$")
        if xp then return { xpointer = xp } end
        local page = entry.position:match("^page:(%d+)$")
        if page then return { page = tonumber(page) } end
    end
    return nil
end

-- Drift counters with schema-v1 defaults.
function Cache.counters(entry)
    local rolls = tonumber(entry and entry.roll_count) or 0
    local chars = tonumber(entry and entry.rolled_chars) or 0
    return rolls, chars
end

return Cache
