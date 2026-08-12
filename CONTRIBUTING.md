# Contributing

Thanks for looking. This is a small, deliberately plain codebase — the barrier to changing it should
be low.

## Building

```bash
swift build -c release   # requires Xcode 15+ / Swift 5.9, macOS 13+
swift test
./build.sh               # → Understanley.app + Understanley.dmg
```

There is nothing else to install. Which brings us to the one hard rule.

## No dependencies

`Package.swift` has no `dependencies:` array and should keep it that way. Everything — the layout
engines, the JSON handling, the regex extractors, the Keychain access, the HTTP clients — is Swift
and the system frameworks.

This is not asceticism. It is why the app is 6 MB, starts instantly, builds in 25 seconds, and can
be audited by one person in an afternoon — and this is a tool people point at their private source
code, so being auditable matters more than being convenient to write.

If a change seems to need a package, that is worth a conversation first.

## House style

- **Swift 6 concurrency, today.** `-strict-concurrency=complete` is on, so the compiler flags every
  data race it can see. Those arrive as *warnings* under Swift 5 language mode — which is exactly
  why the build must stay at **zero warnings**: that is what turns them into a gate.
- **No force-unwraps, no `try!`, no unguarded `Int(someFloat)`.** That last one traps on NaN,
  infinity and overflow; a layout that diverges must degrade, not crash. `floorToInt` exists for it.
- **Comments say *why*.** The code already says what. A comment that repeats the line above it is
  noise; one that records the bug that put it there is the most valuable thing in the file.
- **Fail loudly on writes, quietly on reads.** A corrupt cache means "no cache". A failed export
  means an error the user can see.
- **Never `removeItem`** on anything a user made — `trashItem`.

## Testing

`swift test` runs everything, and it is the whole gate — there is no CI, so run it before you push.
The export tests in particular assert things a person will not notice: that the exported HTML has no
network references, and that the SVG and PNG are actually well-formed. Tests live beside the failure mode they guard, not beside the class
they exercise, and most exist because something actually broke.

Two things worth knowing:

- **Fixtures go in `NSTemporaryDirectory()`.** Never a real project directory.
- **Reachability is not correctness.** Several features in this project were written, reviewed, and
  never called by anything. Before claiming a feature is done, check that something calls it:

  ```bash
  grep -rn "\bmyNewFunction\b" Sources/ Tests/ | grep -v "func myNewFunction"
  ```

  Expect false positives for protocol conformances and functions passed as values. It still found
  five real gaps here.

## Verifying by hand

The canvas cannot be asserted about in a unit test, so there are headless modes for everything
underneath it:

```bash
Understanley --analyze <path>              # nodes, edges, layers, timing
Understanley --layout <path>               # bounds, overlaps, edge crossings, per-engine timing
Understanley --inspect <root> <file>       # what the extractor and resolver saw in one file
Understanley --enrich <path> [--provider]  # a real describe pass, bounded
Understanley --domains <path>              # derive business domains
Understanley --export <path> <outdir>      # all four formats
Understanley --ondevice-probe "<prompt>"   # one Apple Intelligence request, verbatim
```

`--layout` is the one to run after touching layout: crossings and overlaps regress visibly and
silently otherwise.

## Interoperability

`.ua/knowledge-graph.json` is upstream's schema, exactly. A graph written here opens in the
Understand-Anything dashboard and vice versa. Changes that break that need a good reason —
"no lock-in in either direction" is a feature, not an accident.

Node and edge types from modes this app does not implement (Figma's `page`, `screen`, `token`) are
still accepted on read for the same reason.

## Sending a change

Keep the diff to one idea. Say what broke and how you know it is fixed — a before/after from
`--layout` or `--analyze` is worth more than a paragraph.
