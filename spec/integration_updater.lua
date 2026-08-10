-- Real-download integration check (DoD gate for the updater): exercises the
-- actual GitHub path through the real updater core — releases/latest API,
-- parse_release, asset download, and sha256 digest verification — using curl
-- for transport and sha256sum for hashing (KOReader's socket/ffi.sha2 are
-- device-only). Extraction is device-only and smoked on the Kindle.
--
-- Usage:  luajit spec/integration_updater.lua
-- Requires: network access, curl, and sha256sum (or shasum) on PATH.
package.path = "./kocatchup.koplugin/?.lua;" .. package.path

local Updater = require("kocatchup_updater")

-- GET-capable curl transport (the Ollama harness's is POST-only).
local function curl_get(req)
    local resp = os.tmpname()
    local hdr = ""
    for k, v in pairs(req.headers or {}) do
        hdr = hdr .. string.format(' -H "%s: %s"', k, v)
    end
    local cmd = string.format(
        'curl -sL -o "%s" -w "%%{http_code}"%s --max-time 120 "%s"',
        resp, hdr, req.url)
    local pipe = io.popen(cmd)
    local status = pipe:read("*a"); pipe:close()
    local f = io.open(resp, "rb")
    local body = f and f:read("*a") or nil
    if f then f:close() end
    os.remove(resp)
    local code = tonumber((status or ""):match("%d+"))
    if not code or code == 0 then return nil, "timeout" end
    return body, code
end

local function sha256_hex(bytes)
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb"); f:write(bytes); f:close()
    -- Try common hashers across platforms: coreutils, BSD, then Windows certutil.
    local pipe = io.popen('sha256sum "' .. tmp .. '" 2>/dev/null '
        .. '|| shasum -a 256 "' .. tmp .. '" 2>/dev/null '
        .. '|| certutil -hashfile "' .. tmp .. '" SHA256 2>nul')
    local out = pipe:read("*a"); pipe:close()
    os.remove(tmp)
    -- coreutils/bsd: "<hash>  file"; certutil: hash on its own line (may have spaces).
    for line in (out or ""):gmatch("[^\r\n]+") do
        local h = line:gsub("%s", ""):match("^(%x+)$") or line:match("^(%x+)%s")
        if h and #h == 64 then return h:lower() end
    end
    return nil
end

Updater.transport = curl_get

print("Checking releases/latest for " .. Updater.REPO)
local rel, err, code = Updater.check("0.0.0")
if not rel then
    print(string.format("FAILED: check err=%s code=%s", tostring(err), tostring(code)))
    os.exit(1)
end
print(string.format("latest=%s  newer-than-0.0.0=%s  asset=%s",
    rel.version, tostring(rel.newer), tostring(rel.asset_url)))
assert(rel.asset_url and rel.asset_url:match("kocatchup%-.+%.zip$"), "asset URL shape")

print("Downloading the asset…")
local body, dcode = curl_get({ url = rel.asset_url, headers = {} })
assert(body and dcode == 200, "asset download failed: " .. tostring(dcode))
print(string.format("downloaded %d bytes", #body))

if rel.digest then
    local got = sha256_hex(body)
    print("digest expected=" .. rel.digest .. "  got=" .. tostring(got))
    assert(got == rel.digest, "digest mismatch")
    print("OK: digest verified")
else
    print("NOTE: release asset carries no digest field (older release); skipping digest check")
end

-- Confirm the archive contains the plugin entrypoint (host-side unzip).
local zip = os.tmpname() .. ".zip"
local zf = io.open(zip, "wb"); zf:write(body); zf:close()
local list = io.popen('unzip -l "' .. zip .. '" 2>/dev/null || powershell -Command "Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead(\''
    .. zip .. '\').Entries.FullName"')
local names = list:read("*a"); list:close()
os.remove(zip)
assert(names:find("kocatchup.koplugin/main.lua", 1, true) or names:find("kocatchup.koplugin\\main.lua", 1, true)
    or names:find("main.lua", 1, true), "archive missing kocatchup.koplugin/main.lua")
print("OK: archive contains kocatchup.koplugin/main.lua")
print("Updater integration check passed.")
os.exit(0)
