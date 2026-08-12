import Foundation

/// Headless entry points.
///
/// These exist so the analysis pipeline can be exercised without a window: CI
/// runs `--analyze` on every push, and during development it is the fastest way
/// to see exactly what the graph contains. Everything here writes to stdout and
/// never touches the UI layer.
enum CLI {
    static func printUsage() {
        print(
            """
            Understanley — turn any folder into a knowledge graph.

            Usage:
              Understanley                          Launch the app
              Understanley --analyze <path>         Analyze a folder and print a summary
              Understanley --inspect <root> <file>  Show what the extractor found in one file
              Understanley --layout <path>          Run both layout engines and report geometry
              Understanley --enrich <path> [--provider <id>] [--model <id>] [--limit <n>]
                                                  Describe nodes with a model and print samples
              Understanley --domains <path> [--provider <id>] [--model <id>]
                                                  Derive business domains with a model
              Understanley --export <path> <outdir> Write every export format and report sizes
              Understanley --version                Print the version
              Understanley --help                   Show this message
            """
        )
    }

    /// One on-device request, reported verbatim.
    ///
    /// Lives here rather than in `App` deliberately: `App` is `@MainActor`, so
    /// a `Task` started there inherits the main actor and the semaphore below
    /// deadlocks against the very thread the work needs. Every CLI mode runs
    /// from this non-isolated enum for that reason.
    static func runOnDeviceProbe(user: String, system: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            print(await AppleFoundationProvider.probe(system: system, user: user))
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Derives domains headlessly and prints them.
    static func runDomains(path: String, providerID: String, model: String?) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let spec = ProviderRegistry.spec(providerID) else {
            FileHandle.standardError.write(Data("Unknown provider \"\(providerID)\"\n".utf8))
            Foundation.exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            let diagnostics = DiagnosticsCollector()
            do {
                let provider = try ProviderRegistry.makeProvider(spec, model: model)
                print("Provider: \(provider.displayName) → \(provider.destination)\n")

                var graph = try await AnalysisPipeline(diagnostics: diagnostics)
                    .run(projectRoot: root)
                let extractor = DomainExtractor(provider: provider, diagnostics: diagnostics)
                let result = await extractor.run(graph: graph) { progress in
                    print("  \(progress.message)")
                }

                guard !result.nodes.isEmpty else {
                    let report = await diagnostics.snapshot()
                    for issue in report.issues.prefix(3) where issue.category == .providerFailure {
                        print("  [warn] \(issue.message)")
                    }
                    Foundation.exit(1)
                }

                for node in result.nodes where node.type == .domain {
                    print("\n  ▸ \(node.name)")
                    print("    \(node.summary)")
                    let flows = result.nodes.filter { flow in
                        flow.type == .flow && flow.id.hasPrefix(node.id + ":flow:")
                    }
                    for flow in flows {
                        print("      · \(flow.name)")
                        let steps = result.nodes.filter { $0.id.hasPrefix(flow.id + ":step:") }
                        for step in steps { print("          \(step.name)") }
                    }
                }

                let crossings = result.edges.filter { $0.type == .cross_domain }.count
                print("\n  \(result.nodes.count) nodes, \(result.edges.count) edges "
                      + "(\(crossings) cross-domain)")

                // Persist, so the app opens straight onto the domain map.
                graph.nodes.append(contentsOf: result.nodes)
                graph.edges.append(contentsOf: result.edges)
                try? GraphStore.save(graph, projectRoot: root)
            } catch {
                FileHandle.standardError.write(
                    Data("Domain extraction failed: \(error.localizedDescription)\n".utf8)
                )
                Foundation.exit(1)
            }
        }
        semaphore.wait()
    }

    /// Analyzes and writes every export format, so they can be validated
    /// without a save panel.
    static func runExport(path: String, outputDirectory: String) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            defer { semaphore.signal() }
            do {
                let graph = try await AnalysisPipeline(diagnostics: DiagnosticsCollector())
                    .run(projectRoot: root)
                var arrays = GraphArrays.compile(graph)
                arrays.universe = ForceLayout.compute(arrays)
                arrays.blueprint = LayeredLayout.compute(arrays).positions

                try FileManager.default.createDirectory(
                    atPath: outputDirectory, withIntermediateDirectories: true
                )
                var failures = 0
                for format in ExportService.Format.allCases {
                    let url = URL(fileURLWithPath: outputDirectory)
                        .appendingPathComponent("graph.\(format.fileExtension)")
                    do {
                        try ExportService.write(
                            format, graph: graph, arrays: arrays,
                            positions: arrays.universe, to: url
                        )
                        let attributes = try? FileManager.default
                            .attributesOfItem(atPath: url.path)
                        let size = (attributes?[.size] as? Int) ?? 0
                        let label = format.fileExtension
                            .padding(toLength: 5, withPad: " ", startingAt: 0)
                        print("  \(label) \(size / 1024) KB   \(url.path)")
                    } catch {
                        // One format failing must not deny the user the others.
                        failures += 1
                        print("  \(format.fileExtension): \(error.localizedDescription)")
                    }
                }
                if failures > 0 { Foundation.exit(1) }
            } catch {
                FileHandle.standardError.write(
                    Data("Export failed: \(error.localizedDescription)\n".utf8)
                )
                Foundation.exit(1)
            }
        }
        semaphore.wait()
    }

    /// Analyzes, then describes the graph with a provider, printing samples.
    ///
    /// Enrichment is the one part of the app that leaves the machine, so being
    /// able to exercise it headlessly — pointed at a local model, on a folder
    /// of your choosing — is how you confirm what it actually sends and gets
    /// back before trusting it with a real codebase.
    static func runEnrich(path: String, providerID: String, model: String?, limit: Int) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let spec = ProviderRegistry.spec(providerID) else {
            let known = ProviderRegistry.all.map(\.id).joined(separator: ", ")
            FileHandle.standardError.write(
                Data("Unknown provider \"\(providerID)\". Known: \(known)\n".utf8)
            )
            Foundation.exit(1)
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            let diagnostics = DiagnosticsCollector()
            do {
                let provider = try ProviderRegistry.makeProvider(spec, model: model)
                print("Provider: \(provider.displayName) → \(provider.destination)")

                var full = try await AnalysisPipeline(diagnostics: diagnostics).run(projectRoot: root)

                // Bounded on purpose: this is a smoke test, not a billing event.
                //
                // The limit trims a *copy*. Handing the trimmed graph onward and
                // then persisting it wrote a four-node stub over a real
                // eighty-eight-node graph — the truncation is for the request,
                // never for the file on disk.
                var graph = full
                if limit > 0 {
                    let described = full.nodes.filter(\.isEnriched)
                    let pending = full.nodes.filter { !$0.isEnriched }.prefix(limit)
                    graph.nodes = described + pending
                }
                print("Describing \(graph.nodes.filter { !$0.isEnriched }.count) nodes…\n")

                let enricher = Enricher(
                    provider: provider, projectRoot: root, diagnostics: diagnostics
                )
                let collected = Collector()
                await enricher.run(graph: graph) { descriptions, progress in
                    await collected.add(descriptions)
                    if !progress.message.isEmpty { print("  \(progress.message)") }
                }

                let narrative = await enricher.describeNarrative(graph: graph)
                let all = await collected.all
                graph.apply(all)
                graph.apply(narrative)
                full.apply(narrative)
                // Persist against the FULL graph, like the app does. A
                // verification mode that throws away the work it just paid a
                // model for is not verifying the same thing the app does.
                full.apply(all)
                if !all.isEmpty { try? GraphStore.save(full, projectRoot: root) }
                print("\n  \(all.count) nodes described\n")
                for node in full.nodes.filter(\.isEnriched).prefix(8) {
                    print("  \(node.name)")
                    print("    \(node.summary)")
                    print("    tags: \(node.tags.joined(separator: ", "))\n")
                }

                if !narrative.layerDescriptions.isEmpty {
                    print("  Layer descriptions:")
                    for layer in graph.layers.prefix(4) {
                        print("    \(layer.name): \(ScanLimits.clamp(layer.description, 90))")
                    }
                    print("")
                }

                let report = await diagnostics.snapshot()
                for issue in report.issues.prefix(5) where issue.category == .providerFailure {
                    print("  [warn] \(issue.message)")
                }
            } catch {
                FileHandle.standardError.write(
                    Data("Enrichment failed: \(error.localizedDescription)\n".utf8)
                )
                Foundation.exit(1)
            }
        }
        semaphore.wait()
    }

    /// Accumulates batch results across the enricher's concurrent callbacks.
    private actor Collector {
        var all: [String: Enricher.Description] = [:]
        func add(_ descriptions: [String: Enricher.Description]) {
            all.merge(descriptions) { current, _ in current }
        }
    }

    /// Runs both layout engines and reports geometry quality and timing.
    ///
    /// The canvas cannot be inspected from a terminal, but the numbers that
    /// decide whether it will look right — how many nodes overlap, how many
    /// edges cross, how long the layout takes — can be. This is the headless
    /// stand-in for looking at the picture, and it is what makes a layout
    /// regression visible in CI.
    static func runLayout(path: String) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            defer { semaphore.signal() }
            let diagnostics = DiagnosticsCollector()
            do {
                let graph = try await AnalysisPipeline(diagnostics: diagnostics).run(projectRoot: root)
                var arrays = GraphArrays.compile(graph)
                print("\(arrays.count) nodes, \(arrays.edgeCount) edges")

                var started = Date()
                let layered = LayeredLayout.compute(arrays)
                let layeredTime = Date().timeIntervalSince(started)
                arrays.blueprint = layered.positions

                started = Date()
                let forced = ForceLayout.compute(arrays)
                let forceTime = Date().timeIntervalSince(started)
                arrays.universe = forced

                report("Blueprint", positions: layered.positions, arrays: arrays, seconds: layeredTime)
                report("Universe", positions: forced, arrays: arrays, seconds: forceTime)

                // The spatial index backs both culling and hit-testing; if it
                // cannot find a node at its own position, neither can a click.
                let index = SpatialIndex(positions: forced)
                var found = 0
                for i in 0..<arrays.count where index.nearest(
                    to: forced[i], within: 1, positions: forced
                ) != nil { found += 1 }
                print("\n  spatial index: \(found)/\(arrays.count) nodes locatable")
            } catch {
                FileHandle.standardError.write(Data("Layout failed: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        semaphore.wait()
    }

    private static func report(
        _ label: String, positions: [SIMD2<Float>], arrays: GraphArrays, seconds: TimeInterval
    ) {
        let bounds = GraphArrays.bounds(of: positions, padding: 0)

        // Overlap: how many node pairs sit closer than their combined radii.
        // Sampled through a grid rather than all-pairs, which would be minutes
        // on a large graph.
        var buckets: [Int64: [Int]] = [:]
        let cell: Float = 120
        for (i, p) in positions.enumerated() {
            // Saturating: this measures layouts, including broken ones, so it
            // must survive a coordinate the layout should never have produced.
            let key = Int64(floorToInt(p.x / cell)) << 32 ^ Int64(floorToInt(p.y / cell))
            buckets[key, default: []].append(i)
        }
        var overlaps = 0
        for bucket in buckets.values where bucket.count > 1 {
            for a in 0..<bucket.count {
                for b in (a + 1)..<bucket.count {
                    let delta = positions[bucket[a]] - positions[bucket[b]]
                    let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                    let minimum = (arrays.radii[bucket[a]] + arrays.radii[bucket[b]]) * 1.4
                    if distance < minimum { overlaps += 1 }
                }
            }
        }

        // Edge crossings, sampled — an exact count is O(E²).
        let sampleSize = min(arrays.edgeCount, 600)
        var crossings = 0
        if sampleSize > 1 {
            let stride = max(1, arrays.edgeCount / sampleSize)
            var sampled: [(SIMD2<Float>, SIMD2<Float>)] = []
            for e in Swift.stride(from: 0, to: arrays.edgeCount, by: stride) {
                sampled.append((positions[Int(arrays.edgeSource[e])],
                                positions[Int(arrays.edgeTarget[e])]))
            }
            for a in 0..<sampled.count {
                for b in (a + 1)..<sampled.count where segmentsCross(sampled[a], sampled[b]) {
                    crossings += 1
                }
            }
        }

        print("""

          \(label)
            bounds     \(floorToInt(Float(bounds.width))) × \(floorToInt(Float(bounds.height)))
            overlaps   \(overlaps)
            crossings  \(crossings) (sampled from \(sampleSize) edges)
            time       \(String(format: "%.3fs", seconds))
        """)
    }

    private static func segmentsCross(
        _ p: (SIMD2<Float>, SIMD2<Float>), _ q: (SIMD2<Float>, SIMD2<Float>)
    ) -> Bool {
        func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Int {
            let value = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(value) < 0.0001 { return 0 }
            return value > 0 ? 1 : 2
        }
        // Shared endpoints are adjacency, not a crossing.
        if p.0 == q.0 || p.0 == q.1 || p.1 == q.0 || p.1 == q.1 { return false }
        return orientation(p.0, p.1, q.0) != orientation(p.0, p.1, q.1)
            && orientation(q.0, q.1, p.0) != orientation(q.0, q.1, p.1)
    }

    /// Dumps everything the pipeline derives for a single file.
    ///
    /// This exists because "the graph has no import edges" is not a debuggable
    /// statement — the answer is always in one specific file's extraction or
    /// resolution, and this prints exactly that.
    static func runInspect(root: String, relativePath: String) {
        let projectRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let path = PosixPath.normalize(relativePath)

        guard let source = FileRead.text(at: projectRoot + "/" + path) else {
            FileHandle.standardError.write(Data("Cannot read \(path)\n".utf8))
            Foundation.exit(1)
        }

        let language = LanguageRegistry.language(for: path)
        let category = LanguageRegistry.category(for: path)
        print("\(path)")
        print("  language: \(language)   category: \(category.rawValue)")

        guard let analysis = ExtractorRegistry.shared.analyze(
            source: source, language: language, path: path
        ) else {
            print("  no extractor claims this language")
            Foundation.exit(0)
        }

        print("  functions: \(analysis.functions.count)  classes: \(analysis.classes.count)"
              + "  imports: \(analysis.imports.count)  exports: \(analysis.exports.count)")
        for fn in analysis.functions.prefix(12) {
            print("    fn  \(fn.name)(\(fn.params.joined(separator: ", "))) "
                  + "[\(fn.lineRange.start)–\(fn.lineRange.end)]")
        }
        for cls in analysis.classes.prefix(12) {
            print("    ty  \(cls.name)  methods: \(cls.methods.prefix(6).joined(separator: ", "))")
        }

        // Resolution needs the whole file list, so this runs a real scan.
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            defer { semaphore.signal() }
            let scanner = ProjectScanner(diagnostics: DiagnosticsCollector())
            let scan = await scanner.scan(projectRoot: projectRoot)
            let resolver = ImportResolver(root: projectRoot, files: scan.files)
            guard let file = scan.files.first(where: { $0.path == path }) else {
                print("  NOTE: this file was excluded from the scan by an ignore rule")
                return
            }
            print("  imports:")
            for importInfo in analysis.imports.prefix(30) {
                let resolved = resolver.resolve(importInfo, from: file)
                let arrow = resolved.isEmpty ? "→ (external or unresolved)" : "→ \(resolved.joined(separator: ", "))"
                print("    \(importInfo.source)  \(arrow)")
            }
        }
        semaphore.wait()
    }

    static func runAnalyze(path: String) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            FileHandle.standardError.write(Data("Not a directory: \(root)\n".utf8))
            Foundation.exit(1)
        }

        print("Analyzing \(root)")
        let started = Date()

        let semaphore = DispatchSemaphore(value: 0)
        // The pipeline is async; the CLI has no run loop to drive it, so block
        // the calling thread until it finishes.
        Task {
            defer { semaphore.signal() }
            let diagnostics = DiagnosticsCollector()
            do {
                let pipeline = AnalysisPipeline(diagnostics: diagnostics)
                let result = try await pipeline.run(projectRoot: root) { stage in
                    print("  \(stage.description)")
                }
                report(result, diagnostics: await diagnostics.snapshot(), elapsed: Date().timeIntervalSince(started))
            } catch {
                FileHandle.standardError.write(Data("Analysis failed: \(error.localizedDescription)\n".utf8))
                Foundation.exit(1)
            }
        }
        semaphore.wait()
    }

    private static func report(_ graph: KnowledgeGraph, diagnostics: DiagnosticsReport, elapsed: TimeInterval) {
        let nodesByType = Dictionary(grouping: graph.nodes, by: \.type).mapValues(\.count)
        let edgesByType = Dictionary(grouping: graph.edges, by: \.type).mapValues(\.count)

        print("")
        print("  \(graph.project.name) — \(graph.project.description)")
        print("  languages:  \(graph.project.languages.joined(separator: ", "))")
        if !graph.project.frameworks.isEmpty {
            print("  frameworks: \(graph.project.frameworks.joined(separator: ", "))")
        }
        print("")
        print("  \(graph.nodes.count) nodes, \(graph.edges.count) edges, \(graph.layers.count) layers, \(graph.tour.count) tour steps")
        print("")
        print("  nodes by type:")
        for (type, count) in nodesByType.sorted(by: { $0.value > $1.value }) {
            print("    \(type.rawValue.padded(to: 12)) \(count)")
        }
        print("  edges by type:")
        for (type, count) in edgesByType.sorted(by: { $0.value > $1.value }) {
            print("    \(type.rawValue.padded(to: 16)) \(count)")
        }
        print("  layers:")
        for layer in graph.layers {
            print("    \(layer.name.padded(to: 22)) \(layer.nodeIds.count) files")
        }

        if !diagnostics.isEmpty {
            print("")
            print("  diagnostics: \(diagnostics.total) (\(diagnostics.correctedCount) corrected, \(diagnostics.droppedCount) dropped, \(diagnostics.fatalCount) fatal)")
            for issue in diagnostics.issues.prefix(10) {
                print("    [\(issue.level.rawValue)] \(issue.message)")
            }
            if diagnostics.issues.count > 10 {
                print("    … and \(diagnostics.total - 10) more")
            }
        }

        print("")
        print(String(format: "  done in %.2fs", elapsed))
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
