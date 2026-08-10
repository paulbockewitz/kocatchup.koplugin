# Compatibility

KO Catchup is a document-reader plugin (loads with a book open). It uses only
widely-available KOReader surfaces (WidgetContainer, Dispatcher, Trapper,
NetworkMgr, TextViewer, DocSettings, LuaSettings) plus, for the optional
in-app updater, `ffi/archiver` and `ffi/sha2`.

## Tested

- **KOReader:** developed and tested against the 2026.x series. KOReader has no
  stable third-party plugin API, so behavior on much older or newer builds may
  vary — please open an issue if something breaks after a KOReader update.
- **Devices:** verified on Kindle (jailbroken) and the KOReader desktop
  emulator. The core (recap generation, caching, rolling updates, break offers)
  uses portable APIs and is expected to work on Kobo, PocketBook, and Android;
  reports from those devices are welcome.

## Requirements

- A network connection and a provider API key (OpenAI-compatible, Anthropic, or
  a self-hosted Ollama endpoint) — see the README.
- The in-app updater additionally needs `ffi/archiver` and `ffi/sha2` (bundled
  in default KOReader releases) and a CA bundle for verified TLS; where these
  are absent it degrades gracefully (the updater reports it's unavailable and
  manual USB install still works).

## Known limitations

- PDF/DjVu recaps are best-effort (text-layer dependent); image-only documents
  cannot be recapped.
- The in-app updater's install (unzip + folder swap) has been exercised on
  Kindle; other platforms' filesystem behavior is expected-compatible but not
  yet field-confirmed.
