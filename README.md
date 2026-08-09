# KO Catchup — a KOReader plugin

KO Catchup generates a spoiler-safe AI catch-up recap of the book you're reading — the [KOReader](https://koreader.rocks) equivalent of Kindle's *Story So Far* feature. One menu tap summarizes the book **up to your current reading position**, using an LLM you configure (cloud API or local Ollama).

**Spoiler safety is structural:** only text located *before* your current position is ever sent to the model, and the prompt additionally forbids speculation about what comes next. If you jump back to re-read earlier chapters, the plugin refuses to show a saved recap that covers a later point without warning you first.

## Features

- Recap of the current book up to your reading position, from the reader menu (Tools → KO Catchup → Generate recap), or bind the "KO Catchup: recap" action to a gesture.
- Works with EPUB/FB2/HTML/MOBI (crengine); best-effort for PDF/DjVu with a text layer. Image-only PDFs are detected and refused with a clear message.
- Providers: any **OpenAI-compatible** chat-completions endpoint (OpenAI, OpenRouter, Groq, self-hosted **Ollama**) or the **Anthropic** messages API.
- Recap length presets (short / standard / detailed).
- Per-book caching: re-opening a recap at the same position is instant and works offline; if you've read further, you choose between the saved recap and a fresh one.
- Optional background pre-generation: opt in and a recap is silently prepared shortly after you open a book (only when Wi-Fi is already on), so viewing it is instant.
- Cancellable generation: the network call runs in a subprocess — tap to cancel; the UI never freezes.

## Installation

1. Download this repository (or a release zip) and locate the `kocatchup.koplugin` folder.
2. Copy the **whole folder** into KOReader's `plugins` directory on your device:
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/`
   - **Kindle (jailbroken):** `/mnt/us/koreader/plugins/`
   - **PocketBook:** `/mnt/ext1/applications/koreader/plugins/`
   - **Android:** `koreader/plugins/` in KOReader's storage directory
   - **Desktop (Linux/macOS):** `~/.config/koreader/plugins/`
3. Restart KOReader. With a book open, find **KO Catchup** in the Tools menu.

Tested against KOReader **2026.07** (KOReader has no stable plugin API; other versions may need adjustments — please open an issue).

## Configuration

Open a book, then: Tools → KO Catchup → Settings.

| Setting | Meaning |
|---|---|
| Provider | OpenAI-compatible (OpenAI, OpenRouter, Groq, Ollama…) or Anthropic |
| API key | Your provider key. May be blank for local Ollama |
| Base URL | Blank = provider default. Ollama: `http://localhost:11434/v1` |
| Model | e.g. `gpt-4o-mini`, `claude-haiku-4-5`, `llama3.1` |
| Recap length | Short (~150 words), Standard (~400), Detailed (~800) |
| Max input size | How much recent book text is sent to the model (default 100,000 characters) |
| Pre-generate on book open | Off by default. When on, a recap is silently generated ~20s after opening a book — only if Wi-Fi is already connected (it never prompts or wakes the radio) and the cached recap is missing or stale |

### Provider examples

- **OpenAI:** provider *OpenAI-compatible*, API key `sk-…`, base URL blank, model `gpt-4o-mini`.
- **Anthropic:** provider *Anthropic*, API key `sk-ant-…`, base URL blank, model `claude-haiku-4-5`.
- **OpenRouter:** provider *OpenAI-compatible*, API key `sk-or-…`, base URL `https://openrouter.ai/api/v1`, any hosted model.
- **Ollama on your LAN (private, no cloud):** provider *OpenAI-compatible*, API key blank, base URL `http://<your-pc>:11434/v1`, model e.g. `llama3.1`.

> **Ollama note:** Ollama silently truncates prompts longer than the model's context window (`num_ctx`, often 2k–8k tokens by default). For recaps, either lower **Max input size** (e.g. 20,000 characters ≈ 5k tokens) or raise `num_ctx` in your Ollama model settings — otherwise the recap will quietly cover only part of the text.

## Privacy and security

- **Book text leaves your device.** Generating a recap sends up to *Max input size* characters of the current book (plus title/author) to the endpoint you configured, at your expense. Nothing is ever sent without an explicit tap — unless you opt into *Pre-generate on book open*, which sends book text automatically after opening a book (that's its purpose; leave it off if you don't want automatic sending). For full privacy, use Ollama on your own machine.
- **Your API key is stored unencrypted** in KOReader's settings directory (`settings/kocatchup.lua`). Anyone with filesystem access to the device can read it — use device-level lock/encryption where available, and prefer revocable, spend-limited keys.
- **TLS:** HTTPS connections verify the server certificate against KOReader's bundled CA store when present. If you enter a plain `http://` base URL for a remote host, the plugin warns you before saving it (local Ollama over `http://localhost` is fine).

## Known limitations

- **Long books:** only the most recent ~100k characters (about a normal-length novel's worth) before your position are summarized. On very long books, early events may be missing from the recap. Full-book chunked summarization is planned follow-up work.
- **PDF/DjVu:** page-text extraction is noisy, and the lookback is capped at 250 pages before your current page.
- Series-level recaps (Kindle's "Recaps" across earlier books in a series) are out of scope for now.

## Development

```
kocatchup.koplugin/   the plugin (copy this folder to your device)
spec/                  busted-compatible unit tests + KOReader module mocks
```

Run the tests with [busted](https://lunarmodules.github.io/busted/) (`busted spec`) or, with no dependencies beyond LuaJIT, via the bundled mini-runner:

```sh
luajit spec/runner.lua
```

The mocks in `spec/helper.lua` stand in for KOReader modules, so the suite runs without a KOReader checkout. For an end-to-end smoke test, copy the plugin into a [KOReader desktop build](https://github.com/koreader/koreader) and generate a recap against a local Ollama.

With an Ollama server running locally, `luajit spec/integration_ollama.lua [model]` generates a real recap through the plugin's provider layer (request building, live HTTP, response parsing — the socket layer swapped for curl, since luasocket ships inside KOReader).

`spec/smoke_pluginloader.lua` drives KOReader's real `frontend/pluginloader.lua` (vendored in `_koreader/`) against an install-layout copy of the plugin in `./plugins/`, verifying discovery, `_meta` merge, plugin-manager listing, reader-context menu registration, the doc-only flag, and the disable path — copy the plugin folder into `./plugins/` first, or see the invocation in the repo history.

## Release packaging

A release zip contains just the plugin folder, so it can be unzipped straight into `plugins/`:

```sh
zip -r kocatchup-<version>.zip kocatchup.koplugin
```

## Credits and license

- Text-extraction and subprocess patterns follow the excellent [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin) (GPL-3.0).
- Inspired by Amazon Kindle's "Story So Far" / "Recaps" features.

GPL-3.0 — see [LICENSE](LICENSE).
