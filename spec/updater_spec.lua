local H = require("helper")
local Updater = require("kocatchup_updater")
local Json = require("kocatchup_json")

-- A recording filesystem seam with configurable existence and load results.
local function make_fs(opts)
    opts = opts or {}
    local calls = { rename = {}, purge = {} }
    local existing = opts.existing or {}
    return {
        calls = calls,
        exists = function(path) return existing[path] == true end,
        purge = function(path) table.insert(calls.purge, path); existing[path] = nil end,
        rename = function(from, to)
            table.insert(calls.rename, { from, to })
            existing[from] = nil; existing[to] = true
        end,
        write = function(path) existing[path] = true end,
        read = function(path) return opts.reads and opts.reads[path] end,
        loadcheck = function(path)
            if opts.bad_load and opts.bad_load[path] then return false end
            return true
        end,
    }
end

local function all_manifest_present(staged)
    local t = {}
    for _, m in ipairs(Updater.MANIFEST) do t[staged .. "/" .. m] = true end
    return t
end

describe("kocatchup_updater version compare", function()
    it("orders major.minor.patch numerically", function()
        assert.is_true(Updater.is_newer("0.5.0", "0.4.0"))
        assert.is_true(Updater.is_newer("0.4.1", "0.4.0"))
        assert.is_true(Updater.is_newer("1.0.0", "0.9.9"))
        assert.is_true(Updater.is_newer("v0.5.0", "0.4.0"))
        assert.is_false(Updater.is_newer("0.4.0", "0.4.0"))
        assert.is_false(Updater.is_newer("0.4.0", "0.5.0"))
        assert.is_false(Updater.is_newer("garbage", "0.4.0"))
        assert.is_false(Updater.is_newer("0.4.0", nil))
    end)
end)

describe("kocatchup_updater.parse_release", function()
    it("picks the kocatchup-*.zip asset with its digest", function()
        local decoded = Json.decode([[{
            "tag_name": "v0.5.0",
            "assets": [
                {"name": "notes.txt", "browser_download_url": "u1"},
                {"name": "kocatchup-0.5.0.zip", "browser_download_url": "u2",
                 "digest": "sha256:abcd1234"}
            ]
        }]])
        local rel = Updater.parse_release(decoded)
        assert.are.equal("0.5.0", rel.version)
        assert.are.equal("u2", rel.asset_url)
        assert.are.equal("abcd1234", rel.digest)
    end)

    it("returns nil when the asset is absent", function()
        local decoded = Json.decode('{"tag_name":"v0.5.0","assets":[{"name":"x.txt"}]}')
        assert.is_nil(Updater.parse_release(decoded))
    end)
end)

describe("kocatchup_updater.meta_version", function()
    it("extracts the version by text pattern without executing the chunk", function()
        local text = 'return {\n  fullname = "KO Catchup",\n  version = "0.5.0",\n}\n'
        assert.are.equal("0.5.0", Updater.meta_version(text))
    end)

    it("does not evaluate a side-effecting _meta body", function()
        _G.__kocatchup_meta_ran = nil
        local text = '_G.__kocatchup_meta_ran = true\nreturn { version = "0.5.0" }'
        assert.are.equal("0.5.0", Updater.meta_version(text))
        assert.is_nil(_G.__kocatchup_meta_ran)
    end)
end)

describe("kocatchup_updater.unsafe_entry", function()
    it("flags absolute and parent-traversal paths, passes normal ones", function()
        assert.is_true(Updater.unsafe_entry("/abs/path"))
        assert.is_true(Updater.unsafe_entry("../escape"))
        assert.is_true(Updater.unsafe_entry("a/../../b"))
        assert.is_true(Updater.unsafe_entry("C:\\win"))
        assert.is_false(Updater.unsafe_entry("kocatchup.koplugin/main.lua"))
        assert.is_false(Updater.unsafe_entry("kocatchup.koplugin/sub/x.lua"))
    end)
end)

describe("kocatchup_updater.check", function()
    before_each(function() Updater.transport = nil end)

    local RELEASE = '{"tag_name":"v0.5.0","assets":[{"name":"kocatchup-0.5.0.zip",'
        .. '"browser_download_url":"u","digest":"sha256:deadbeef"}]}'

    it("reports a newer release", function()
        Updater.transport = function() return RELEASE, 200 end
        local rel = Updater.check("0.4.0")
        assert.is_true(rel.newer)
        assert.are.equal("0.5.0", rel.version)
        assert.are.equal("deadbeef", rel.digest)
    end)

    it("reports up-to-date", function()
        Updater.transport = function() return RELEASE, 200 end
        assert.is_false(Updater.check("0.5.0").newer)
    end)

    it("maps a rate-limit 403 to http_error", function()
        Updater.transport = function() return '{"message":"rate"}', 403 end
        local rel, err, code = Updater.check("0.4.0")
        assert.is_nil(rel)
        assert.are.equal("http_error", err)
        assert.are.equal(403, code)
    end)

    it("maps a missing asset to no_asset", function()
        Updater.transport = function() return '{"tag_name":"v0.5.0","assets":[]}', 200 end
        local rel, err = Updater.check("0.4.0")
        assert.is_nil(rel)
        assert.are.equal("no_asset", err)
    end)
end)

describe("kocatchup_updater.run pipeline", function()
    local BODY = "zipbytes"
    local DIGEST = "goodhash"

    local function base_paths(staged)
        return {
            live = "/plugins/kocatchup.koplugin",
            staging = "/plugins/kocatchup.staging",
            staged_plugin = staged,
            backup = "/plugins/kocatchup.bak",
            download = "/plugins/kocatchup.staging/dl.zip",
            url = "https://example/kocatchup-0.5.0.zip",
            digest = DIGEST,
            tag = "v0.5.0",
        }
    end

    local function wire(fs, extract_ok)
        Updater.transport = function() return BODY, 200 end
        Updater.hasher = function(b) return b == BODY and DIGEST or "other" end
        Updater.archiver = { extract = function() return extract_ok ~= false, extract_ok == false and "extract_failed" or nil end }
        Updater.fs = fs
    end

    before_each(function()
        H.reset()
        Updater.transport, Updater.hasher, Updater.archiver, Updater.fs = nil, nil, nil, nil
    end)

    it("happy path: purges stale dirs, then swaps live<->staged in order", function()
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local existing = all_manifest_present(staged)
        existing["/plugins/kocatchup.koplugin"] = true
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        wire(fs, true)

        local ok = Updater.run(base_paths(staged))
        assert.is_true(ok)
        -- Two renames, in the safe order.
        assert.are.equal("/plugins/kocatchup.koplugin", fs.calls.rename[1][1])
        assert.are.equal("/plugins/kocatchup.bak", fs.calls.rename[1][2])
        assert.are.equal(staged, fs.calls.rename[2][1])
        assert.are.equal("/plugins/kocatchup.koplugin", fs.calls.rename[2][2])
    end)

    it("digest mismatch aborts before extract, purges staging, no rename", function()
        local fs = make_fs({ existing = { ["/plugins/kocatchup.koplugin"] = true } })
        wire(fs, true)
        Updater.hasher = function() return "WRONG" end
        local extract_called = false
        Updater.archiver = { extract = function() extract_called = true return true end }

        local ok, err = Updater.run(base_paths("/s/kocatchup.koplugin"))
        assert.is_nil(ok)
        assert.are.equal("digest_mismatch", err)
        assert.is_false(extract_called)
        assert.are.equal(0, #fs.calls.rename)
    end)

    it("validation failure (missing module) purges staging and never renames", function()
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local existing = all_manifest_present(staged)
        existing[staged .. "/kocatchup_llm.lua"] = nil -- one module missing
        existing["/plugins/kocatchup.koplugin"] = true
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        wire(fs, true)

        local ok, err = Updater.run(base_paths(staged))
        assert.is_nil(ok)
        assert.are.equal("validate_failed", err)
        assert.are.equal(0, #fs.calls.rename)
        assert.truthy(#fs.calls.purge > 0)
    end)

    it("validation failure (truncated module fails loadcheck) never renames", function()
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local fs = make_fs({ existing = (function()
                local e = all_manifest_present(staged)
                e["/plugins/kocatchup.koplugin"] = true
                return e
            end)(),
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' },
            bad_load = { [staged .. "/kocatchup_prompts.lua"] = true } })
        wire(fs, true)

        local ok, err = Updater.run(base_paths(staged))
        assert.is_nil(ok)
        assert.are.equal("validate_failed", err)
        assert.are.equal(0, #fs.calls.rename)
    end)

    it("download failure returns typed error, no extract, no rename", function()
        local fs = make_fs({ existing = { ["/plugins/kocatchup.koplugin"] = true } })
        wire(fs, true)
        Updater.transport = function() return nil, "timeout" end
        local ok, err = Updater.run(base_paths("/s/kocatchup.koplugin"))
        assert.is_nil(ok)
        assert.are.equal("download_failed", err)
        assert.are.equal(0, #fs.calls.rename)
    end)

    it("recovers a stale backup when the live folder is missing (crash mid-swap)", function()
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local existing = all_manifest_present(staged)
        existing["/plugins/kocatchup.bak"] = true -- live absent, backup present
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        wire(fs, true)

        local ok = Updater.run(base_paths(staged))
        assert.is_true(ok)
        -- First rename restores backup -> live before the normal swap.
        assert.are.equal("/plugins/kocatchup.bak", fs.calls.rename[1][1])
        assert.are.equal("/plugins/kocatchup.koplugin", fs.calls.rename[1][2])
    end)

    it("keeps the backup after a successful swap (rollback copy)", function()
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local existing = all_manifest_present(staged)
        existing["/plugins/kocatchup.koplugin"] = true
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        wire(fs, true)

        assert.is_true(Updater.run(base_paths(staged)))
        assert.is_true(fs.exists("/plugins/kocatchup.bak"),
            "backup must survive the swap for Revert to previous version")
    end)

    it("a failed attempt does not consume an existing rollback backup", function()
        local fs = make_fs({ existing = {
            ["/plugins/kocatchup.koplugin"] = true,
            ["/plugins/kocatchup.bak"] = true,
        } })
        wire(fs, true)
        Updater.transport = function() return nil, "timeout" end

        local ok, err = Updater.run(base_paths("/s/kocatchup.koplugin"))
        assert.is_nil(ok)
        assert.are.equal("download_failed", err)
        assert.is_true(fs.exists("/plugins/kocatchup.bak"),
            "backup purge must wait until just before the swap")
    end)

    it("fs-fidelity: real rename-onto-nonempty errors, proving step 0 prevents the wedge", function()
        -- A rename seam with realistic semantics: renaming onto an existing
        -- path errors. Without the step-0 purge, the swap would wedge.
        local staged = "/plugins/kocatchup.staging/kocatchup.koplugin"
        local existing = all_manifest_present(staged)
        existing["/plugins/kocatchup.koplugin"] = true
        existing["/plugins/kocatchup.bak"] = true -- stale backup from a prior run
        local rename_errors = {}
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        local real_rename = fs.rename
        fs.rename = function(from, to)
            if existing[to] then
                table.insert(rename_errors, to)
                error("ENOTEMPTY: " .. to)
            end
            real_rename(from, to)
        end
        wire(fs, true)

        local ok = Updater.run(base_paths(staged))
        assert.is_true(ok, "step 0 must purge the stale backup so the swap succeeds")
        assert.are.equal(0, #rename_errors)
    end)
end)

describe("kocatchup_updater rollback", function()
    local LIVE = "/plugins/kocatchup.koplugin"
    local BAK = "/plugins/kocatchup.bak"
    local STAGING = "/plugins/kocatchup.staging"

    local function rollback_paths()
        return { live = LIVE, staging = STAGING, backup = BAK,
            staged_plugin = STAGING .. "/kocatchup.koplugin",
            download = STAGING .. "/dl.zip" }
    end

    local function backup_manifest_present()
        local t = {}
        for _, m in ipairs(Updater.MANIFEST) do t[BAK .. "/" .. m] = true end
        return t
    end

    before_each(function()
        Updater.transport, Updater.hasher, Updater.archiver, Updater.fs = nil, nil, nil, nil
    end)

    it("backup_version reads the kept copy's _meta version", function()
        Updater.fs = make_fs({ existing = { [BAK] = true },
            reads = { [BAK .. "/_meta.lua"] = 'version = "0.5.4"' } })
        assert.are.equal("0.5.4", Updater.backup_version(rollback_paths()))
    end)

    it("backup_version is nil with no backup", function()
        Updater.fs = make_fs({})
        assert.is_nil(Updater.backup_version(rollback_paths()))
    end)

    it("happy path: parks live in staging, restores backup, purges", function()
        local existing = backup_manifest_present()
        existing[LIVE] = true
        existing[BAK] = true
        local fs = make_fs({ existing = existing })
        Updater.fs = fs

        assert.is_true(Updater.rollback(rollback_paths()))
        assert.are.equal(LIVE, fs.calls.rename[1][1])
        assert.are.equal(STAGING, fs.calls.rename[1][2])
        assert.are.equal(BAK, fs.calls.rename[2][1])
        assert.are.equal(LIVE, fs.calls.rename[2][2])
        assert.is_true(fs.exists(LIVE))
        assert.is_false(fs.exists(BAK), "rollback consumes the backup")
    end)

    it("returns no_backup when nothing was kept", function()
        local fs = make_fs({ existing = { [LIVE] = true } })
        Updater.fs = fs
        local ok, err = Updater.rollback(rollback_paths())
        assert.is_nil(ok)
        assert.are.equal("no_backup", err)
        assert.are.equal(0, #fs.calls.rename)
    end)

    it("refuses a backup with a missing or unparseable module", function()
        local existing = backup_manifest_present()
        existing[LIVE] = true
        existing[BAK] = true
        existing[BAK .. "/kocatchup_llm.lua"] = nil -- one module missing
        local fs = make_fs({ existing = existing })
        Updater.fs = fs
        local ok, err = Updater.rollback(rollback_paths())
        assert.is_nil(ok)
        assert.are.equal("validate_failed", err)
        assert.are.equal(0, #fs.calls.rename)
    end)

    it("a crash between the renames is recovered by run()'s step 0", function()
        -- Simulate: rename1 done (live parked in staging), rename2 never ran.
        local existing = backup_manifest_present()
        existing[BAK] = true -- live absent
        local staged = STAGING .. "/kocatchup.koplugin"
        for _, m in ipairs(Updater.MANIFEST) do existing[staged .. "/" .. m] = true end
        local fs = make_fs({ existing = existing,
            reads = { [staged .. "/_meta.lua"] = 'version = "0.5.0"' } })
        Updater.transport = function() return "zipbytes", 200 end
        Updater.hasher = function() return "goodhash" end
        Updater.archiver = { extract = function() return true end }
        Updater.fs = fs

        local ok = Updater.run({ live = LIVE, staging = STAGING, backup = BAK,
            staged_plugin = staged, download = STAGING .. "/dl.zip",
            url = "https://example/z.zip", digest = "goodhash", tag = "v0.5.0" })
        assert.is_true(ok)
        assert.are.equal(BAK, fs.calls.rename[1][1])
        assert.are.equal(LIVE, fs.calls.rename[1][2])
    end)
end)
