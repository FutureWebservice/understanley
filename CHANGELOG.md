# Changelog

All notable changes to Understanley are recorded here.

## v0.1.0 — first public release

The complete app: deterministic analysis, both graph views, optional AI, and every export format.

Shipped as a **2.4 MB `Understanley.dmg`** on the release page, and buildable from source with
`./build.sh`. The DMG is ad-hoc signed rather than notarised, so a downloaded copy needs one
first-launch approval; a locally built one does not.

**Analysis** — 28 extractors covering 16 code languages plus shell/PowerShell and 12 non-code
formats. Import resolution across TypeScript `paths`, NodeNext rewriting, `jsconfig.json`, Python
dots, Go modules, PSR-4, JVM/C# type indices and Swift package targets. Call graph, `tested_by`
pairing, architectural layer detection, guided-tour ordering, framework detection, and a four-tier
schema validator that repairs rather than rejects.

**Views** — Blueprint (layered Sugiyama) and Universe (Barnes-Hut force layout), both computed on
load so switching morphs rather than reloads.

**Navigation** — search with results and camera fly-to, category filters, file tree, code viewer,
path finder, guided tour player, focus mode, diff mode, staleness banner, opt-in auto-update.

**AI, optional** — Apple Intelligence on-device, Claude Code CLI, OpenAI Codex CLI, Anthropic,
OpenAI, OpenRouter, Ollama, and any custom endpoint. Descriptions are journaled per node, so they
survive re-analysis, a provider switch and a reopen.

**Export** — filtered JSON, SVG, PNG, and a self-contained offline HTML viewer.

**Interoperability** — reads and writes upstream's `.ua/knowledge-graph.json` byte-compatibly.

136 tests. Zero warnings on a clean release build. Zero dependencies.
