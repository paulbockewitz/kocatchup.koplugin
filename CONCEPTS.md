# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Updater

### Seam
An injection point separating the updater's pure, unit-tested pipeline from device-only KOReader bindings. The four seams are transport (verified HTTPS), hasher (sha256), archiver (zip extraction), and fs (filesystem operations).

A seam's real implementation runs only on the device; the test suite stubs all of them. This makes seam bindings the plugin's untested surface — a wrong call in a real binding passes every spec and fails only on hardware.

### Validate-before-swap
The named install discipline: a downloaded update is extracted to staging and fully validated — every manifest module present and parseable, its version matching the release tag — before the running install is touched. Only then does the swap run, as two atomic same-filesystem renames (live → backup, staged → live), so an interrupted or invalid update can never leave the device without a working copy.
