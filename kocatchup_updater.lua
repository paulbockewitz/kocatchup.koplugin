-- Self-updater core: fetches this repo's latest GitHub release and installs
-- it on-device. The version/parse/validate logic is pure and unit-tested;
-- device-only work (network, unzip, sha256, filesystem swap) sits behind
-- injectable seams, mirroring Llm.transport. Security posture: verified TLS
-- only (no unverified fallback), sha256 digest pinning across GitHub's
-- redirect, path-traversal-safe extraction, and validate-before-swap.
local Json = require("kocatchup_json")

local Updater = {
    REPO = "paulbockewitz/kocatchup.koplugin",
    -- Every .lua module the running install ships; the staged copy must
    -- contain all of them (present + parseable) before the swap.
    MANIFEST = {
        "main.lua", "_meta.lua",
        "kocatchup_cache.lua", "kocatchup_extractor.lua", "kocatchup_json.lua",
        "kocatchup_llm.lua", "kocatchup_llm_anthropic.lua", "kocatchup_llm_openai.lua",
        "kocatchup_prompts.lua", "kocatchup_settings.lua", "kocatchup_updater.lua",
    },
    MAX_BYTES = 20 * 1024 * 1024, -- generous vs the ~50KB real asset
}

function Updater.api_url()
    return "https://api.github.com/repos/" .. Updater.REPO .. "/releases/latest"
end

-- Injectable seams (bound to real implementations at runtime; stubbed in tests):
--   transport(req) -> body, code | nil, err   (contract of Llm.transport)
--   hasher(bytes) -> sha256 hex string
--   archiver.extract(zip_path, dest_dir) -> ok, err   (rejects unsafe entries)
--   fs.exists / fs.purge / fs.rename / fs.write / fs.read / fs.loadcheck
Updater.transport = nil
Updater.hasher = nil
Updater.archiver = nil
Updater.fs = nil

-- version -------------------------------------------------------------------

function Updater.parse_version(s)
    if type(s) ~= "string" then return nil end
    local maj, min, pat = s:match("^v?(%d+)%.(%d+)%.(%d+)")
    if not maj then return nil end
    return { tonumber(maj), tonumber(min), tonumber(pat) }
end

function Updater.is_newer(remote, localv)
    local r, l = Updater.parse_version(remote), Updater.parse_version(localv)
    if not r or not l then return false end
    for i = 1, 3 do
        if r[i] ~= l[i] then return r[i] > l[i] end
    end
    return false
end

-- release parsing -----------------------------------------------------------

-- Returns { version, asset_url, digest } for the kocatchup-*.zip asset, or nil.
function Updater.parse_release(decoded)
    if type(decoded) ~= "table" or type(decoded.assets) ~= "table" then return nil end
    local version = type(decoded.tag_name) == "string"
        and decoded.tag_name:match("^v?(.+)$") or nil
    for _, a in ipairs(decoded.assets) do
        if type(a) == "table" and type(a.name) == "string"
            and a.name:match("^kocatchup%-.+%.zip$") then
            local digest = a.digest
            if type(digest) == "string" then
                digest = digest:match("^sha256:(.+)$") or digest
            end
            return { version = version, asset_url = a.browser_download_url, digest = digest }
        end
    end
    return nil
end

-- Reads the version field from _meta.lua TEXT — never loads/executes it.
function Updater.meta_version(text)
    if type(text) ~= "string" then return nil end
    return text:match("version%s*=%s*[\"']([%d%.]+)[\"']")
end

-- True when an archive entry path would escape the extraction directory.
function Updater.unsafe_entry(path)
    if type(path) ~= "string" or path == "" then return true end
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then return true end
    if path:match("^%a:[/\\]") then return true end -- windows drive-absolute
    for seg in path:gmatch("[^/\\]+") do
        if seg == ".." then return true end
    end
    return false
end

-- network -------------------------------------------------------------------

-- Queries releases/latest and compares against local_version.
-- Returns { version, asset_url, digest, newer } or nil, err(, code).
function Updater.check(local_version)
    local body, code = Updater.transport({
        url = Updater.api_url(),
        method = "GET",
        headers = { ["Accept"] = "application/vnd.github.v3+json" },
    })
    if not body then return nil, "http_error" end
    if code ~= 200 then return nil, "http_error", code end
    local ok, decoded = pcall(Json.decode, body)
    if not ok then return nil, "bad_response" end
    local rel = Updater.parse_release(decoded)
    if not rel or not rel.version then return nil, "no_asset" end
    rel.newer = Updater.is_newer(rel.version, local_version)
    return rel
end

-- Returns body, or nil, err, detail (detail is the raw transport reason, for
-- logging/diagnostics — surfaced so a device failure isn't an opaque code).
local function download(url)
    local body, code = Updater.transport({ url = url, method = "GET", headers = {} })
    if not body then return nil, "download_failed", tostring(code) end
    if code ~= 200 then return nil, "http_error", "code=" .. tostring(code) end
    if #body > Updater.MAX_BYTES then return nil, "download_failed", "oversize" end
    return body
end

-- validation ----------------------------------------------------------------

-- staged_plugin is the extracted `.../kocatchup.koplugin` directory.
function Updater.validate(staged_plugin, tag)
    for _, mod in ipairs(Updater.MANIFEST) do
        local path = staged_plugin .. "/" .. mod
        if not Updater.fs.exists(path) then return nil, "validate_failed" end
        if not Updater.fs.loadcheck(path) then return nil, "validate_failed" end
    end
    local text = Updater.fs.read(staged_plugin .. "/_meta.lua")
    local v = Updater.meta_version(text or "")
    local want = tag and tag:match("^v?(.+)$") or tag
    if not v or (want and v ~= want) then return nil, "validate_failed" end
    return true
end

-- install pipeline ----------------------------------------------------------

-- paths = { live, staging, staged_plugin, backup, download, url, digest, tag }
-- Recovery-then-validate-then-swap. Returns true, or nil, typed_error.
function Updater.run(p)
    local fs = Updater.fs

    -- Step 0: reclaim state from a prior interrupted run.
    if not fs.exists(p.live) and fs.exists(p.backup) then
        fs.rename(p.backup, p.live)
    end
    fs.purge(p.staging)
    fs.purge(p.backup)

    local body, err, detail = download(p.url)
    if not body then return nil, err, detail end

    if p.digest and Updater.hasher(body) ~= p.digest then
        return nil, "digest_mismatch"
    end

    fs.write(p.download, body)
    local ok, exerr = Updater.archiver.extract(p.download, p.staging)
    if not ok then
        fs.purge(p.staging)
        return nil, exerr or "extract_failed"
    end

    local vok, verr = Updater.validate(p.staged_plugin, p.tag)
    if not vok then
        fs.purge(p.staging)
        return nil, verr
    end

    -- Critical window: two atomic same-filesystem renames.
    fs.rename(p.live, p.backup)
    fs.rename(p.staged_plugin, p.live)
    fs.purge(p.backup)
    fs.purge(p.staging)
    return true
end

return Updater
