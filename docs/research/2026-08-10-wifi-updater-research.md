# Wi-Fi self-update feature — research notes (shelved 2026-08-10)

Feature deferred by decision; this captures the verified research so a future
plan can start warm. Prerequisite already shipped: `KoCatchup.VERSION` +
`_meta.lua` version (sync-checked by a unit test) and GitHub Releases with a
`kocatchup-X.Y.Z.zip` asset (top-level dir inside is exactly
`kocatchup.koplugin/`).

## Verified mechanics (from assistant.koplugin, appstore.koplugin, KOReader core)

- **Version check:** `GET https://api.github.com/repos/paulbockewitz/kocatchup.koplugin/releases/latest`
  (`Accept: application/vnd.github.v3+json`); compare `tag_name` (strip leading
  `v`) against `KoCatchup.VERSION`, full-semver compare.
- **Download:** KOReader's bundled `socket.http` handles https directly and
  follows GitHub's cross-host 302 redirects automatically (live-verified) — no
  manual redirect handling. Use `socketutil:set_timeout(FILE_BLOCK_TIMEOUT,
  FILE_TOTAL_TIMEOUT)` + `socketutil.file_sink(file)`; sentinel codes
  `socketutil.TIMEOUT_CODE` etc. Prefer our **release asset zip** over the
  source archive (precedents use source zips; our repo zip would drag in
  spec/docs, and the asset's top dir is already `kocatchup.koplugin/`).
- **Unzip on device:** `require("ffi/archiver")` (libarchive-backed) —
  `Archiver.Reader:new()`, `arc:open(path)`, `for entry in arc:iterate()`,
  `arc:extractToPath(entry.path, dest)`, `arc:close()`. No miniz; `ffi/zlib`
  is a raw stream tool, not an unzipper.
- **Install (self-replacement while running is proven safe):** stage under the
  KOReader data dir (same filesystem → atomic renames): download + extract to
  temp, validate the extracted `kocatchup.koplugin/` fully **before** touching
  the live folder, then `os.rename(live → backup)`, `os.rename(new → live)`,
  purge temp+backup. Failure at any pre-rename step leaves the install
  untouched; USB is the recovery path. Loaded Lua modules stay in memory
  across the swap; avoid lazy requires afterward.
- **Restart:** `UIManager:askForRestart(msg)` — portable (real restart prompt
  on `Device:canRestart()` platforms, "takes effect on next restart" info
  elsewhere). `UIManager:restartKOReader()` = quit with exit code 85.
- **Wrapping:** whole flow in `Trapper:wrap`; network phases in
  `Trapper:dismissableRunInSubprocess`; keep the extract/swap phase
  non-dismissable.

## Design decisions sketched (unconfirmed — user paused before scope confirm)

- Manual "Check for updates" only in v1 (likely under the Settings submenu);
  auto-check on open deferred.
- TLS posture: precedents set `https.cert_verify = false`; we should do better
  since this downloads executable code — attempt verified TLS via the existing
  CA-bundle discovery first, and require an explicit user-consent dialog
  before any unverified fallback.
- Release discipline required: every release bumps `VERSION` (main.lua +
  _meta.lua), tags `vX.Y.Z`, uploads `kocatchup-X.Y.Z.zip`.

Verified source copies (assistant_updater.lua, ffi_archiver.lua,
socketutil.lua, luasocket http.lua) were saved to the session scratchpad;
re-fetch from upstream if needed — the require paths and signatures above are
the durable part.
