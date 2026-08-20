# Changelog

All notable changes to Understanley are recorded here.

## Unreleased

**Settings, rebuilt.** One scrolling column of AI options became four tabs — Model, Project,
Interface, About — because the sheet had more to say than fitted, and because the model settings are
the only ones carrying a privacy consequence.

- **Fixed: the Settings sheet did not scroll.** The canvas installs an app-wide `NSEvent` monitor for
  the scroll wheel and swallows any event landing inside its own frame. A sheet is a separate
  window laid over that frame, so its coordinates fell inside it and every scroll aimed at the
  provider list was eaten as a pan — leaving the list stuck with most providers unreachable. Events
  from a sheet, and events from a window that has one attached, are now left alone. The same bug
  affected the ask panel, the ignore editor and the shortcuts sheet.
- **The provider list scrolls in a region of its own**, so changing provider no longer pushes the
  key and model fields off the bottom.
- **Test connection** — one real round trip to the configured provider, reporting the reply and how
  long it took, or the exact error. Available for every provider, and it sends nothing from your
  project.
- **Describe new nodes automatically** — opt-in, off by default, runs the enrichment pass by itself
  once analysis lands.
- **New project actions** — reveal `.ua/knowledge-graph.json` in Finder, clear recent projects.
- **New interface settings** — canvas scroll direction and scroll speed (clamped, so a hand-edited
  default cannot make the canvas unusable), and replaying the first-run tour.
- **About tab** — version, author, upstream credit, and a plain statement of what the app does with
  your code.

142 tests.

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
