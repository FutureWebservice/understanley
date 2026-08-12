# Security

Understanley reads source code from folders you choose, and — only if you enable AI — sends bounded
excerpts to the provider you picked. It has no server, no telemetry and no auto-update.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) instead.

Useful in a report: what an attacker controls, what they achieve, and the smallest project or
`.ua/knowledge-graph.json` that reproduces it.

## What is in scope

- Anything that reads a file outside the analysed project — the code viewer allowlist and the
  traversal checks around it are the boundary that matters most, since a `.ua/knowledge-graph.json`
  can be written by anyone.
- Anything that sends project content anywhere the UI did not name first.
- Secrets leaving the Keychain: appearing in the graph, an export, a log or a prompt.
- Prompt injection from project content that changes what the app *does*, rather than only what a
  summary says.

## What is out of scope

- The Gatekeeper prompt on an unsigned build. That is expected — see the README.
- A model writing a wrong or unflattering summary. Enrichment is advisory; the deterministic graph
  is the source of truth.
- Denial of service from pointing the app at a pathological folder, unless it escapes the documented
  limits in `ScanLimits`.
