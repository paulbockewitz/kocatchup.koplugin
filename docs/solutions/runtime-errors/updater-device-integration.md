---
title: Device-only updater seams crashed on real Kindle despite 115 passing unit specs
date: 2026-08-10
category: runtime-errors
module: in-app-updater
problem_type: runtime_error
component: tooling
symptoms:
  - "Asset download fails with HTTP nil when GitHub 302-redirects from github.com to objects.githubusercontent.com"
  - "Install subprocess dies with attempt to call field 'makePath' (a nil value); UI shows only the opaque message Update failed: nil"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [updater, device-integration, redirect-handling, koreader, luasocket, seams]
---

# Device-only updater seams crashed on real Kindle despite 115 passing unit specs

## Problem

KO Catchup's in-app Wi-Fi updater (pure pipeline in `kocatchup_updater.lua`, device-only seam bindings in `main.lua`) passed its entire unit suite but failed twice in a row on the real device (jailbroken Kindle, KOReader nightly v2026.07). The seam architecture that made the core logic testable also meant the real seam implementations — the only code that touches KOReader's actual modules — never ran anywhere except on the device, and both failures lived exactly there.

## Symptoms

- v0.5.0: tapping **Update** froze the e-ink UI, then the download failed with the message `HTTP nil`.
- v0.5.1: download and sha256 digest check succeeded, then the install step died with the opaque message `Update failed: nil`.
- `koreader/crash.log` (retrieved over MTP) held the real traceback for the second failure: `attempt to call field 'makePath' (a nil value)`.

## What Didn't Work

- **Retrying the update in-app from the broken version** — chicken-and-egg: a device running the broken updater cannot use that updater to install the fix. The only way forward was a one-time manual sideload.
- **Relying on luasocket's automatic redirect following** — KOReader's pinned luasocket does not reliably carry the verified-TLS `create` factory across GitHub's cross-host 302 (`github.com` → `objects.githubusercontent.com`). The API version check (single host, no redirect) worked fine, which masked the problem; only the redirected asset download broke, surfacing as `HTTP nil`.
- **Expecting the unit suite to cover the seam bindings** — the 115 specs exercise the pure pipeline against stubbed transport/hasher/archiver/fs seams. The seams' *contracts* were thoroughly tested; their *real implementations* in `main.lua` are precisely the device-only code the suite stubs out, so a wrong `require` in a binding is invisible until it runs on hardware.

## Solution

Three code fixes plus a verification technique, shipped as v0.5.4 (commit `b7d52af`).

**1. The makePath fix (the v0.5.1 crash).** In KOReader, directory creation lives in the frontend `util` module; `ffi/util` has `purgeDir`, `copyFile`, etc. but no `makePath`. Two seam call sites in `main.lua` used the wrong module:

```lua
-- before (crashes on device: ffi/util has no makePath)
require("ffi/util").makePath(dir)

-- after
require("util").makePath(dir)
```

Both `real_updater_extract` (dest dir creation) and the `fs.write` seam in `real_updater_fs` were corrected (`main.lua` lines ~74–118).

**2. Manual redirect following with per-hop verified TLS (the v0.5.0 `HTTP nil`).** `https_get_once` issues a single verified request with `redirect = false` and a fresh `ssl.https` `create` factory (`verify = "peer"`, pinned cafile). `real_updater_transport` then follows redirects itself — max 5 hops, refusing any non-HTTPS `Location`:

```lua
for _ = 1, 6 do
    if url:lower():sub(1, 6) ~= "https:" then return nil, "insecure_redirect" end
    local ok, code, headers, body = https_get_once(url, cafile)
    if not ok then return nil, "transport:" .. tostring(code) end
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        local loc = headers and (headers.location or headers.Location)
        if not loc or loc == "" then return nil, "redirect_no_location" end
        url = loc
    else
        return body, code
    end
end
return nil, "too_many_redirects"
```

The download+install also moved into `Trapper:dismissableRunInSubprocess` (`KoCatchup:installUpdate`, `main.lua` ~271–307) so the blocking network work can never freeze the e-ink UI, and the user can tap to cancel.

**3. pcall-in-child typed errors (the useless "Update failed: nil").** A crashed subprocess child writes nothing to the result pipe, and `Trapper:dismissableRunInSubprocess` then returns `completed = true` with a `nil` result — which the parent rendered as `Update failed: nil`. The child now wraps the installer in `pcall` and always returns a typed table:

```lua
local pok, ok, err, detail = pcall(Updater.run, paths)
if not pok then return { err = "install_crashed", detail = tostring(ok) } end
return { ok = ok, err = err, detail = detail }
```

Child crashes now surface as a real message (`install_crashed` plus the Lua error text), and the full traceback still lands in `koreader/crash.log`.

**4. Sideload-one-patch-lower verification.** To prove the *fixed* pipeline end-to-end on device — without shipping an unverified updater again — sideload a build whose `VERSION` is one patch lower than the latest GitHub release (device reports `0.5.3` while `0.5.4` is live). The updater then offers a genuine update and exercises the full production path: download across GitHub's redirect → digest check → extract → validate → atomic swap. A no-op version-bump release is an acceptable way to create an update target.

## Why This Works

- **KOReader's module split:** `require("util")` is KOReader's frontend utility module and owns filesystem-path helpers including `makePath`; `require("ffi/util")` is the low-level FFI layer with a different, non-overlapping export set (`purgeDir`, `copyFile`, subprocess helpers — no `makePath`). The two names are easy to conflate and nothing fails until the call executes on device.
- **Per-hop TLS:** issuing a fresh verified request for each redirect hop sidesteps whatever state luasocket loses when auto-following across hosts — every hop gets its own `create` factory with peer verification, and the non-HTTPS guard means no hop can silently downgrade.
- **Subprocess result marshalling:** `dismissableRunInSubprocess` serializes the child's return value over a pipe (via `buffer.encode`). A child that crashes before returning writes nothing, so the parent reads a completed-but-nil result. Only the child itself can distinguish "crashed" from "returned nil" — hence pcall inside the child and a typed error table as the contract.

## Prevention

- **Treat device-only seam bindings as the untested surface.** Before release, grep every `require(...)` in the real seam bindings and confirm each called field actually exists in the target KOReader version's module exports (e.g. check that `util` vs `ffi/util` owns the function you call).
- **Keep a live integration check** (`spec/integration_updater.lua`) that runs the real transport/extract path where possible, so seam bindings are not exclusively exercised in production.
- **Make every subprocess child pcall-and-report.** Never let a child's crash reach the parent as a nil result; return a typed `{ err, detail }` table so failures render as actionable messages.
- **Know where device tracebacks go:** child crashes are recorded in `koreader/crash.log`, retrievable over MTP — that file, not the on-screen message, held the actual root cause.
- **Plan for updater self-recovery:** a broken updater cannot ship its own fix. Keep the sideload procedure documented, and use the one-patch-lower sideload trick to verify updater changes against the real production release before trusting them.

## Related Issues

- Fix commits `7f82887` (0.5.1, manual redirect following) and `b7d52af` (0.5.4, makePath + typed subprocess errors, device-verified).
- Relevant files: `main.lua` (seam bindings ~26–118, `installUpdate` ~271–307), `kocatchup_updater.lua`, `spec/integration_updater.lua`.
- Design history: `docs/plans/2026-08-10-003-feat-wifi-updater-plan.md` (KTD2 anticipated the TLS/redirect interaction; its line 123 note that fs operations use `ffi/util` predates this fix — `makePath` comes from frontend `util`), `docs/research/2026-08-10-wifi-updater-research.md`.
