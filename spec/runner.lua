-- Minimal busted-compatible test runner so the suite runs on stock LuaJIT:
--   luajit spec/runner.lua [spec_name ...]
-- Supports: describe / it / before_each, and the luassert subset the specs
-- use (assert.are.equal, assert.are.same, assert.is_true, assert.is_false,
-- assert.is_nil, assert.is_not_nil, assert.truthy, assert.has_error).
-- With real busted installed, run `busted spec` instead — the spec files
-- themselves are busted-compatible.
package.path = "./kocatchup.koplugin/?.lua;./spec/?.lua;" .. package.path

local passed = 0
local failures = {}
local context_names = {}
local current_before

local function serialize(v, depth)
    depth = depth or 0
    if depth > 4 then return "..." end
    local tv = type(v)
    if tv == "string" then return string.format("%q", v) end
    if tv ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        parts[#parts + 1] = tostring(k) .. "=" .. serialize(val, depth + 1)
        if #parts > 12 then parts[#parts + 1] = "..." break end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_eq(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_eq(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function fail(msg)
    error(msg, 3)
end

local orig_assert = assert
local assert_shim = setmetatable({
    are = {
        equal = function(expected, actual, msg)
            if expected ~= actual then
                fail((msg or "assert.are.equal failed") ..
                    "\n  expected: " .. serialize(expected) ..
                    "\n  actual:   " .. serialize(actual))
            end
        end,
        same = function(expected, actual, msg)
            if not deep_eq(expected, actual) then
                fail((msg or "assert.are.same failed") ..
                    "\n  expected: " .. serialize(expected) ..
                    "\n  actual:   " .. serialize(actual))
            end
        end,
    },
    is_true = function(v, msg)
        if v ~= true then fail((msg or "assert.is_true failed") .. " got " .. serialize(v)) end
    end,
    is_false = function(v, msg)
        if v ~= false then fail((msg or "assert.is_false failed") .. " got " .. serialize(v)) end
    end,
    is_nil = function(v, msg)
        if v ~= nil then fail((msg or "assert.is_nil failed") .. " got " .. serialize(v)) end
    end,
    is_not_nil = function(v, msg)
        if v == nil then fail(msg or "assert.is_not_nil failed") end
    end,
    truthy = function(v, msg)
        if not v then fail((msg or "assert.truthy failed") .. " got " .. serialize(v)) end
    end,
    falsy = function(v, msg)
        if v then fail((msg or "assert.falsy failed") .. " got " .. serialize(v)) end
    end,
    has_error = function(fn, msg)
        local ok = pcall(fn)
        if ok then fail(msg or "assert.has_error: function did not raise") end
    end,
}, { __call = function(_, ...) return orig_assert(...) end })

_G.assert = assert_shim

function _G.describe(name, fn)
    table.insert(context_names, name)
    local saved_before = current_before
    fn()
    current_before = saved_before
    table.remove(context_names)
end

function _G.before_each(fn)
    current_before = fn
end

function _G.it(name, fn)
    local full = table.concat(context_names, " > ") .. " > " .. name
    if current_before then current_before() end
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        io.write(".")
    else
        io.write("F")
        failures[#failures + 1] = { name = full, err = err }
    end
end

require("helper")

local specs = {}
if select("#", ...) > 0 then
    for i = 1, select("#", ...) do specs[#specs + 1] = (select(i, ...)) end
else
    specs = {
        "extractor_spec", "prompts_spec", "llm_spec", "cache_spec", "main_spec",
    }
end

for _, name in ipairs(specs) do
    dofile("spec/" .. name .. ".lua")
end

io.write("\n\n")
if #failures > 0 then
    for _, f in ipairs(failures) do
        io.write("FAILED: " .. f.name .. "\n" .. f.err .. "\n\n")
    end
end
io.write(string.format("%d passed, %d failed\n", passed, #failures))
if #failures > 0 then os.exit(1) end
