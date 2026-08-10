# Feature: Updater rollback — "Revert to previous version" (0.5.5)

- **Objective:** If a new version misbehaves, one tap restores the copy the user updated from. Closes the "no rollback capability if a release breaks" gap surfaced during the distribution review (2026-08-10).

## Requirements

- R1. `Updater.run` keeps the pre-update copy as `kocatchup.bak` instead of purging it after the swap; each update replaces the previous backup (one level of undo).
- R2. A failed update attempt (download/digest/extract/validate) never consumes an existing backup — the old-backup purge happens only immediately before the swap's critical window.
- R3. `Updater.rollback(paths)` validates the backup (manifest present + parseable, no tag check) then mirrors the swap in reverse: live → staging, backup → live, purge staging. A crash between the renames is recovered by `run()`'s step-0 reclaim (live absent + backup present → restore).
- R4. Settings menu gains **Revert to previous version** after "Check for updates", enabled only when a backup exists (`Updater.backup_version` reads its `_meta.lua` by text, never executing it); confirm dialog shows both versions; success prompts a KOReader restart. Typed `no_backup` error message.
- R5. Pure filesystem work, no network — runs inline (no subprocess needed).

## Key Technical Decisions

- KTD1. **Backup lives at `kocatchup.bak` permanently** (not `*.koplugin`, so the plugin loader ignores it; ~50 KB disk cost). Rollback consumes it — after reverting, no further undo until the next update.
- KTD2. **Purge ordering:** step 0 purges only staging; the backup purge moved inside `run()` to just before `rename(live → backup)` — preserving R2 while keeping the rename-onto-nonempty safety proven by the fs-fidelity spec.
- KTD3. Availability begins with the first in-app update **performed by** 0.5.5+ code (0.5.4's updater still purges its backup post-swap).

## Files

`kocatchup_updater.lua` (run purge ordering, backup_version, rollback), `main.lua` (menu item + enabled_func, onRevertUpdate, no_backup message, updaterPaths(nil)), `spec/updater_spec.lua` (backup-kept, failed-attempt survival, rollback happy/no_backup/validate/crash-recovery), `spec/main_spec.lua` (menu order, revert flow, no_backup), `README.md`.

## DoD

125 specs pass; on-device: sideloaded rollback build updates to a real release keeping the backup, Revert restores and restarts into the prior version. Ship only after device verification.
