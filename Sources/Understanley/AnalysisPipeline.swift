import Foundation

/// Runs the deterministic analysis end to end: scan → extract → resolve →
/// build → layer → tour.
///
/// Everything here is offline and free. The result is a complete, navigable
/// graph whose only missing piece is prose — `summary` fields carry a
/// placeholder until enrichment fills them in. That ordering is the whole
/// product argument: the app is useful before any model runs.
struct AnalysisPipeline: Sendable {
    let diagnostics: DiagnosticsCollector

    enum Stage: Sendable {
        case scanning
        case scanned(files: Int, filtered: Int)
        case extracting(done: Int, total: Int)
        case resolving
        case building
        case finished(nodes: Int, edges: Int)

        var description: String {
            switch self {
            case .scanning:
                return "Scanning files…"
            case .scanned(let files, let filtered):
                return filtered > 0
                    ? "Found \(files) files (\(filtered) excluded by your ignore rules)"
                    : "Found \(files) files"
            case .extracting(let done, let total):
                return "Reading structure — \(done)/\(total) files"
            case .resolving:
                return "Resolving imports…"
            case .building:
                return "Building the graph…"
            case .finished(let nodes, let edges):
                return "Built \(nodes) nodes and \(edges) edges"
            }
        }
    }

    enum Failure: LocalizedError {
        case notADirectory(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory(let path):
                return "\(path) is not a folder."
            case .empty(let path):
                return """
                    No analyzable files found in \(path).
                    Everything there is either excluded by the built-in ignore rules \
                    or by a .understandignore file.
                    """
            }
        }
    }

    func run(
        projectRoot: String,
        excludes: [String] = [],
        progress: (@Sendable (Stage) -> Void)? = nil
    ) async throws -> KnowledgeGraph {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectRoot, isDirectory: &isDir),
              isDir.boolValue else {
            throw Failure.notADirectory(projectRoot)
        }

        // ── Scan ──
        progress?(.scanning)
        let scanner = ProjectScanner(diagnostics: diagnostics)
        let scan = await scanner.scan(projectRoot: projectRoot, excludes: excludes)
        progress?(.scanned(files: scan.totalFiles, filtered: scan.filteredByIgnore))
        try Task.checkCancellation()

        guard !scan.files.isEmpty else { throw Failure.empty(projectRoot) }

        // ── Wiki mode ──
        //
        // A Karpathy-pattern wiki is a knowledge base, not a codebase: running
        // the code pipeline over it produces a pile of unconnected document
        // nodes and throws away the only structure it has, which is the
        // wikilinks. Detection is deliberately strict — an `index.md` plus
        // markdown that genuinely cross-links — so an ordinary `docs/` folder
        // is not mistaken for one.
        if let detection = WikiParser.detect(root: projectRoot, files: scan.files) {
            progress?(.building)
            let result = WikiParser.parse(
                root: projectRoot, detection: detection,
                files: scan.files, projectName: scan.projectName
            )
            await diagnostics.add(result.issues)
            await diagnostics.add(
                .autoCorrected, .alias,
                "Read as a knowledge base: \(detection.articleCount) articles, "
                    + "\(result.graph.edges.count) links."
            )
            progress?(.finished(nodes: result.graph.nodes.count,
                                edges: result.graph.edges.count))
            return result.graph
        }

        // ── Extract structure, in parallel ──
        let analyses = await extractAll(root: projectRoot, files: scan.files, progress: progress)
        try Task.checkCancellation()

        // ── Resolve imports ──
        progress?(.resolving)
        let resolver = ImportResolver(root: projectRoot, files: scan.files)
        var analyzed: [GraphBuilder.AnalyzedFile] = []
        analyzed.reserveCapacity(scan.files.count)
        var unresolvedCount = 0

        for file in scan.files {
            let analysis = analyses[file.path] ?? StructuralAnalysis()
            var resolved: [String] = []
            var seen = Set<String>()
            for importInfo in analysis.imports {
                let targets = resolver.resolve(importInfo, from: file)
                if targets.isEmpty, Self.looksInternal(importInfo.source) {
                    unresolvedCount += 1
                }
                for target in targets where target != file.path {
                    if seen.insert(target).inserted { resolved.append(target) }
                }
            }
            analyzed.append(
                GraphBuilder.AnalyzedFile(file: file, analysis: analysis,
                                          resolvedImports: resolved.sortedStable())
            )
        }

        if unresolvedCount > 0 {
            // Worth surfacing but not alarming: a relative import that does not
            // resolve usually means a generated file or a path alias the
            // resolver does not know about.
            let noun = unresolvedCount == 1 ? "import" : "imports"
            let verb = unresolvedCount == 1 ? "was" : "were"
            await diagnostics.add(
                .autoCorrected, .unresolvedImport,
                "\(unresolvedCount) project-relative \(noun) could not be matched to a file "
                    + "and \(verb) skipped."
            )
        }
        try Task.checkCancellation()

        // ── Build ──
        progress?(.building)
        let builder = GraphBuilder(diagnostics: diagnostics)
        let built = await builder.build(scan: scan, analyzed: analyzed)
        let layers = LayerDetector.detect(nodes: built.nodes)
        let tour = TourGenerator.generate(
            nodes: built.nodes, edges: built.edges, layers: layers, entryPoint: scan.entryPoint
        )

        let graph = KnowledgeGraph(
            kind: .codebase,
            project: ProjectMeta(
                name: scan.projectName,
                languages: scan.languages,
                frameworks: scan.frameworks,
                description: scan.projectDescription,
                analyzedAt: ISO8601DateFormatter().string(from: Date()),
                gitCommitHash: GitProbe.headCommit(at: projectRoot) ?? ""
            ),
            nodes: built.nodes,
            edges: built.edges,
            layers: layers,
            tour: tour
        )

        progress?(.finished(nodes: graph.nodes.count, edges: graph.edges.count))
        return graph
    }

    // MARK: - Extraction

    /// Reads and parses every file, bounded to the machine's core count.
    private func extractAll(
        root: String,
        files: [ScannedFile],
        progress: (@Sendable (Stage) -> Void)?
    ) async -> [String: StructuralAnalysis] {
        let width = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunkSize = max(1, (files.count + width - 1) / width)
        let chunks = stride(from: 0, to: files.count, by: chunkSize).map {
            Array(files[$0..<min($0 + chunkSize, files.count)])
        }
        let total = files.count

        var out: [String: StructuralAnalysis] = [:]
        out.reserveCapacity(files.count)
        var completed = 0

        await withTaskGroup(of: [(String, StructuralAnalysis)].self) { group in
            for chunk in chunks {
                group.addTask {
                    var results: [(String, StructuralAnalysis)] = []
                    results.reserveCapacity(chunk.count)
                    for file in chunk {
                        guard let source = FileRead.text(at: root + "/" + file.path) else { continue }
                        guard let analysis = ExtractorRegistry.shared.analyze(
                            source: source, language: file.language, path: file.path
                        ) else { continue }
                        results.append((file.path, analysis))
                    }
                    return results
                }
            }
            for await results in group {
                for (path, analysis) in results { out[path] = analysis }
                completed += results.count
                progress?(.extracting(done: min(completed, total), total: total))
            }
        }
        return out
    }

    /// True when an import specifier names something inside the project rather
    /// than a package — used to decide whether failing to resolve it is worth
    /// reporting.
    private static func looksInternal(_ source: String) -> Bool {
        source.hasPrefix("./") || source.hasPrefix("../") || source.hasPrefix(".")
    }
}
