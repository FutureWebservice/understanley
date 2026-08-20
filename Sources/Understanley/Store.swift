import AppKit
import Foundation
import SwiftUI

/// The app's single source of truth.
///
/// Follows the pattern proven in AgentShare: one `@MainActor ObservableObject`,
/// `@Published private(set)` for anything derived, and every piece of I/O run
/// through `Task.detached` so the main actor only ever assigns a finished
/// result. Views never compute; they read what the store already built.
@MainActor
final class Store: ObservableObject {
    // MARK: Project

    @Published private(set) var projectRoot: String?
    @Published private(set) var graph: KnowledgeGraph?
    @Published private(set) var diagnostics: DiagnosticsReport = .empty
    @Published private(set) var freshness: GitProbe.Freshness?
    /// Paths that differ from what the graph describes. The canvas turns these
    /// into changed and affected node sets.
    @Published private(set) var changedFiles: [String] = []

    // MARK: Analysis lifecycle

    @Published private(set) var isAnalyzing = false
    @Published private(set) var progressMessage: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastAnalysisDuration: TimeInterval?

    /// Recent projects, most recent first. Plain paths — the app is not
    /// sandboxed, so no security-scoped bookmark is needed.
    @Published private(set) var recentProjects: [String] = []

    // MARK: Enrichment

    @Published private(set) var isEnriching = false
    @Published private(set) var enrichmentProgress: Enricher.Progress?
    /// Why the last enrichment run produced nothing.
    ///
    /// Deliberately NOT `lastError`: that one means "this folder could not be
    /// analyzed" and `ContentView` swaps the entire graph away for a full-screen
    /// error when it is set. A provider that is merely signed out must not cost
    /// the user the graph they already have — it is a banner, not a dead end.
    @Published private(set) var enrichmentError: String?

    // MARK: Domains
    //
    @Published private(set) var isDerivingDomains = false
    @Published private(set) var domainProgress: String?

    /// Whether the graph already carries a domain map.
    var hasDomains: Bool {
        graph?.nodes.contains { $0.type == .domain } ?? false
    }
    /// Chosen provider id, or nil when the user has not set one up.
    @Published var providerID: String? {
        didSet { UserDefaults.standard.set(providerID, forKey: Self.providerKey) }
    }

    /// Opt-in tree watching. Off unless the user turns it on.
    @Published var autoUpdate: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdate, forKey: Self.autoUpdateKey)
            syncWatcher()
        }
    }
    /// Opt-in: run the enrichment pass by itself once analysis lands.
    ///
    /// Off by default, and deliberately so — it is the one setting that can
    /// send source code somewhere without the user pressing anything, so it
    /// has to be a decision rather than a default.
    @Published var autoEnrich: Bool {
        didSet { UserDefaults.standard.set(autoEnrich, forKey: Self.autoEnrichKey) }
    }

    private let watcher = FileWatcher()

    private var analysisTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?

    private static let autoUpdateKey = "autoUpdate"
    private static let autoEnrichKey = "autoEnrich"
    private static let recentsKey = "recentProjects"
    private static let providerKey = "providerID"
    private static let maxRecents = 10

    init() {
        autoUpdate = UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
        autoEnrich = UserDefaults.standard.bool(forKey: Self.autoEnrichKey)
        recentProjects = (UserDefaults.standard.array(forKey: Self.recentsKey) as? [String] ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        providerID = UserDefaults.standard.string(forKey: Self.providerKey)

        // Pick a provider on first launch. `detectPreferred` existed but was
        // never called, so a new user's Describe button did nothing at all and
        // said nothing about why. Off the main actor because the probe shells
        // out to look for CLIs and pings localhost for Ollama.
        if providerID == nil {
            Task { [weak self] in
                let found = await Task.detached(priority: .utility) {
                    ProviderRegistry.detectPreferred()?.id
                }.value
                await MainActor.run { [weak self] in
                    guard let self, self.providerID == nil else { return }
                    self.providerID = found
                }
            }
        }
    }

    // MARK: - Enrichment

    /// The provider that would run, or nil when none is configured.
    var activeProviderSpec: ProviderRegistry.Spec? {
        providerID.flatMap(ProviderRegistry.spec)
    }

    /// Nodes still carrying the placeholder summary.
    var undescribedCount: Int {
        graph?.nodes.filter { !$0.isEnriched }.count ?? 0
    }

    func enrich() {
        guard let root = projectRoot, let graph else { return }
        guard !isEnriching else { return }
        guard let spec = activeProviderSpec else {
            // Silently doing nothing is the worst possible answer to a button
            // press, and it was the previous one.
            enrichmentError = """
                No AI provider is set up yet. Open Settings to choose one — \
                Apple Intelligence runs on this Mac for free if it is available.
                """
            return
        }
        guard ProviderRegistry.isAvailable(spec) else {
            enrichmentError = """
                \(spec.displayName) is selected but not usable right now. \
                Open Settings to check it, or pick another provider.
                """
            return
        }

        let provider: any LLMProvider
        do {
            provider = try ProviderRegistry.makeProvider(spec, model: nil)
        } catch {
            lastError = error.localizedDescription
            return
        }

        isEnriching = true
        lastError = nil
        enrichmentError = nil
        enrichmentProgress = Enricher.Progress(
            completed: 0, total: 0, described: 0, failed: 0, message: "Starting…"
        )

        let collector = DiagnosticsCollector()
        let language = ProjectConfig.outputLanguage(projectRoot: root)

        // Merged on the main actor as each batch lands, so summaries appear in
        // the canvas and the inspector while the rest is still running.
        let batches = MainActorRelay<([String: Enricher.Description], Enricher.Progress)> {
            [weak self] descriptions, progress in
            guard let self, self.projectRoot == root else { return }
            if !descriptions.isEmpty { self.graph?.apply(descriptions) }
            self.enrichmentProgress = progress
        }

        enrichmentTask = Task { [weak self] in
            let enricher = Enricher(
                provider: provider, projectRoot: root,
                diagnostics: collector, outputLanguage: language
            )

            await enricher.run(graph: graph) { descriptions, progress in
                await batches.sendAndWait((descriptions, progress))
            }

            // Layers and the tour last, once every node has a summary — the
            // narrative reads better when the parts it describes are described.
            let narrative = await enricher.describeNarrative(graph: graph)

            let report = await collector.snapshot()
            await MainActor.run { [weak self] in
                guard let self, self.projectRoot == root else { return }
                if !narrative.isEmpty { self.graph?.apply(narrative) }
                self.isEnriching = false
                if !report.isEmpty { self.diagnostics = report }

                // A run where every batch failed used to end silently: the
                // spinner stopped, no summary appeared, and the only trace was
                // a line in the diagnostics panel. From the outside that is
                // indistinguishable from "it never finished". Surface the
                // provider's own words — they say what to actually do.
                if let progress = self.enrichmentProgress,
                   progress.described == 0, progress.failed > 0 {
                    let reason = report.issues
                        .first { $0.category == .providerFailure }?
                        .message
                    self.enrichmentError = reason ?? """
                        \(spec.displayName) could not describe anything — \
                        all \(progress.failed) batches failed.
                        """
                }
                // Persist once at the end: the graph is rewritten wholesale and
                // doing it per batch would rewrite a large file dozens of times.
                if let graph = self.graph {
                    try? GraphStore.save(graph, projectRoot: root)
                }
            }
        }
    }

    /// Derives business domains with a model and merges them into the graph.
    ///
    /// Additive and idempotent: an existing domain map is replaced wholesale
    /// rather than merged into, because half of an old map beside half of a new
    /// one is a graph that describes nothing.
    func deriveDomains() {
        guard let root = projectRoot, let graph else { return }
        guard !isDerivingDomains else { return }
        guard let spec = activeProviderSpec, ProviderRegistry.isAvailable(spec) else {
            enrichmentError = """
                Domains need an AI provider — the structure alone cannot say what \
                the software is for. Open Settings to choose one.
                """
            return
        }

        let provider: any LLMProvider
        do {
            provider = try ProviderRegistry.makeProvider(spec, model: nil)
        } catch {
            enrichmentError = error.localizedDescription
            return
        }

        isDerivingDomains = true
        domainProgress = "Starting…"
        enrichmentError = nil

        let collector = DiagnosticsCollector()
        let language = ProjectConfig.outputLanguage(projectRoot: root)
        let relay = MainActorRelay<String> { [weak self] message in
            self?.domainProgress = message
        }

        Task { [weak self] in
            let extractor = DomainExtractor(
                provider: provider, diagnostics: collector, outputLanguage: language
            )
            let result = await extractor.run(graph: graph) { progress in
                relay.send(progress.message)
            }
            let report = await collector.snapshot()

            await MainActor.run { [weak self] in
                guard let self, self.projectRoot == root else { return }
                self.isDerivingDomains = false
                self.domainProgress = nil
                if !report.isEmpty { self.diagnostics = report }

                guard !result.nodes.isEmpty else {
                    self.enrichmentError = report.issues
                        .first { $0.category == .providerFailure }?.message
                        ?? "No domains were identified for this project."
                    return
                }
                self.applyDomains(result, root: root)
            }
        }
    }

    /// Replaces any previous domain map with this one.
    private func applyDomains(
        _ result: (nodes: [GraphNode], edges: [GraphEdge]), root: String
    ) {
        guard var updated = graph else { return }
        let domainTypes: Set<NodeType> = [.domain, .flow, .step]
        let stale = Set(updated.nodes.filter { domainTypes.contains($0.type) }.map(\.id))

        updated.nodes.removeAll { domainTypes.contains($0.type) }
        updated.edges.removeAll { stale.contains($0.source) || stale.contains($0.target) }
        updated.nodes.append(contentsOf: result.nodes)
        updated.edges.append(contentsOf: result.edges)

        graph = updated
        try? GraphStore.save(updated, projectRoot: root)
    }

    func cancelEnrichment() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
        isEnriching = false
    }

    func dismissEnrichmentError() { enrichmentError = nil }

    /// Discards written descriptions so the next run asks the model again.
    ///
    /// Reachable now: with the journal keyed per node and applied on every
    /// open, a summary the user dislikes would otherwise come back forever.
    func clearEnrichmentCache() {
        guard let root = projectRoot else { return }
        Enricher.Journal.clear(projectRoot: root)
    }

    // MARK: - Derived views of the graph

    var nodesById: [String: GraphNode] {
        guard let graph else { return [:] }
        return Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var projectName: String { graph?.project.name ?? PosixPath.basename(projectRoot ?? "") }

    /// True once a graph exists, whether or not it has been enriched.
    var hasGraph: Bool { graph != nil }

    // MARK: - Opening a project

    /// Shows the folder picker. Returns without doing anything if cancelled.
    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a project folder to analyze."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url.path)
    }

    func open(_ path: String) {
        let root = URL(fileURLWithPath: path).standardizedFileURL.path
        // Switching projects mid-analysis cancels the old run rather than
        // letting two pipelines race to assign the graph.
        analysisTask?.cancel()

        projectRoot = root
        graph = nil
        diagnostics = .empty
        freshness = nil
        lastError = nil
        rememberRecent(root)

        // An existing graph — from this app or from the Claude Code plugin —
        // loads instantly, so reopening a project is not a re-analysis. Unless
        // the analyzer has moved on since it was written, in which case the
        // cache is quietly wrong and re-running costs a second.
        let cached = GraphStore.load(projectRoot: root)
        syncWatcher()
        if let cached, !GraphStore.isStale(projectRoot: root) {
            graph = cached
            refreshFreshness()
        } else if let cached {
            // Stale, but not useless. Show it at once so the window is never
            // empty, then re-analyze underneath — the summaries it already
            // carries are handed to the new graph by `analyze`, so the upgrade
            // costs the user nothing they had already paid for.
            graph = cached
            refreshFreshness()
            analyze()
        } else {
            analyze()
        }
    }

    func analyze(excludes: [String] = []) {
        guard let root = projectRoot else { return }
        analysisTask?.cancel()
        isAnalyzing = true
        lastError = nil
        progressMessage = "Starting…"

        let started = Date()
        analysisTask = Task { [weak self] in
            let collector = DiagnosticsCollector()
            do {
                let pipeline = AnalysisPipeline(diagnostics: collector)
                // The progress closure is `@Sendable` and runs off the main
                // actor, so it cannot capture `self` — even weakly, since a
                // weak capture still reads a mutable reference across
                // isolation. It hops to the main actor with a plain value
                // instead, and a one-shot relay owns the hop.
                let relay = MainActorRelay<String> { [weak self] message in
                    self?.progressMessage = message
                }
                var result = try await Task.detached(priority: .userInitiated) {
                    try await pipeline.run(projectRoot: root, excludes: excludes) { stage in
                        relay.send(stage.description)
                    }
                }.value

                guard !Task.isCancelled else { return }
                let report = await collector.snapshot()

                // Carry AI summaries across the re-analysis.
                //
                // Re-analysing rebuilds every node from source, so without this
                // a rebuild silently throws away every summary the user paid
                // for — and the deterministic pipeline reruns for all sorts of
                // reasons: an edited file, a git pull, or the analyzer version
                // moving on. Prose is keyed to a node's identity, not to the
                // run that produced it, so it survives by id.
                let carried = await MainActor.run { [weak self] in
                    self?.graph.map { previous in
                        Dictionary(
                            previous.nodes.filter(\.isEnriched).map {
                                ($0.id, Enricher.Description(summary: $0.summary, tags: $0.tags))
                            },
                            uniquingKeysWith: { a, _ in a }
                        )
                    } ?? [:]
                }
                if !carried.isEmpty { result.apply(carried) }

                // And anything the journal still holds. Between them these two
                // mean a description is written once and then survives
                // re-analysis, an app update, a provider switch and a reopen —
                // the user should never pay twice for the same sentence.
                let restored = Enricher.Journal.load(projectRoot: root).replay(
                    for: result,
                    fingerprints: Enricher.fingerprints(for: result.nodes, graph: result)
                )
                if !restored.isEmpty { result.apply(restored) }

                await MainActor.run { [weak self] in
                    guard let self, self.projectRoot == root else { return }
                    self.graph = result
                    self.diagnostics = report
                    self.isAnalyzing = false
                    self.lastAnalysisDuration = Date().timeIntervalSince(started)
                    self.progressMessage = ""
                    self.refreshFreshness()
                    // Only when the user asked for it, and only when there is
                    // something left to describe — a re-analysis that carried
                    // every summary across should cost nothing.
                    if self.autoEnrich, self.activeProviderSpec != nil,
                       self.undescribedCount > 0 {
                        self.enrich()
                    }
                }

                // Persist after publishing, so the window updates immediately
                // and the write happens off the critical path.
                try? GraphStore.save(result, projectRoot: root)

                // Fingerprints for next time, so the watcher can tell a
                // reformatted file from a restructured one.
                let files = result.nodes.compactMap { node -> ScannedFile? in
                    guard let path = node.filePath,
                          NodeType.fileLevel.contains(node.type) else { return nil }
                    return ScannedFile(path: path, language: LanguageRegistry.language(for: path),
                                       sizeLines: 0, fileCategory: .code)
                }
                let store = Fingerprints.buildStore(
                    projectRoot: root, files: files,
                    gitCommitHash: result.project.gitCommitHash
                )
                try? JSONFile.write(store, to: DataDirectory.fingerprintPath(root), pretty: false)
            } catch is CancellationError {
                // Superseded by another run; the newer one owns the state.
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.projectRoot == root else { return }
                    self.isAnalyzing = false
                    self.progressMessage = ""
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isAnalyzing = false
        progressMessage = ""
    }

    /// Starts or stops the watcher to match the current settings.
    private func syncWatcher() {
        guard autoUpdate, let root = projectRoot else {
            watcher.stop()
            return
        }
        watcher.start(root: root) { [weak self] in
            guard let self, !self.isAnalyzing else { return }
            self.reanalyzeIfStructureChanged(root: root)
        }
    }

    /// Re-analyzes only when the change could actually alter the graph.
    ///
    /// A save is usually a reformat, a comment or a renamed local — none of
    /// which change a single node or edge. Rebuilding anyway costs a full
    /// pipeline run and, worse, visibly resets the view while the user is
    /// mid-thought. The fingerprint store answers "did the structure move?"
    /// by hashing content first and only parsing the files whose hash changed.
    private func reanalyzeIfStructureChanged(root: String) {
        Task { [weak self] in
            let decision = await Task.detached(priority: .utility) { () -> Bool in
                guard let store = JSONFile.read(
                    Fingerprints.Store.self, from: DataDirectory.fingerprintPath(root)
                ) else { return true }  // No baseline: rebuild and make one.

                let scan = await ProjectScanner(diagnostics: DiagnosticsCollector())
                    .scan(projectRoot: root)
                guard !scan.files.isEmpty else { return true }
                let files = scan.files

                let changes = Fingerprints.analyzeChanges(
                    projectRoot: root, store: store, currentFiles: files
                )
                return !changes.structural.isEmpty
                    || !changes.added.isEmpty
                    || !changes.deleted.isEmpty
            }.value

            guard decision else { return }
            await MainActor.run { [weak self] in
                guard let self, self.projectRoot == root, !self.isAnalyzing else { return }
                self.analyze()
            }
        }
    }

    func closeProject() {
        watcher.stop()
        analysisTask?.cancel()
        analysisTask = nil
        cancelEnrichment()
        projectRoot = nil
        graph = nil
        diagnostics = .empty
        freshness = nil
        isAnalyzing = false
        lastError = nil
    }

    // MARK: - Freshness

    func refreshFreshness() {
        guard let root = projectRoot, let hash = graph?.project.gitCommitHash else {
            freshness = nil
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                GitProbe.freshness(at: root, graphCommit: hash)
            }.value
            await MainActor.run { [weak self] in
                guard let self, self.projectRoot == root else { return }
                self.freshness = result
                self.changedFiles = result.changedFiles
            }
        }
    }

    // MARK: - Recents

    private func rememberRecent(_ path: String) {
        var updated = recentProjects.filter { $0 != path }
        updated.insert(path, at: 0)
        updated = Array(updated.prefix(Self.maxRecents))
        recentProjects = updated
        UserDefaults.standard.set(updated, forKey: Self.recentsKey)
    }

    func clearRecents() {
        recentProjects = []
        UserDefaults.standard.set([String](), forKey: Self.recentsKey)
    }

    func forgetRecent(_ path: String) {
        recentProjects.removeAll { $0 == path }
        UserDefaults.standard.set(recentProjects, forKey: Self.recentsKey)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

/// Carries a value from background work to the main actor.
///
/// Background callbacks here are `@Sendable` and fire from whatever thread the
/// work is on. They cannot capture the store — a weak reference is still a
/// mutable reference read across isolation, which Swift 6 rejects. This owns
/// the hop and holds only an immutable closure, which is safe to call anywhere.
final class MainActorRelay<Payload: Sendable>: @unchecked Sendable {
    // Marked `@Sendable` as well as `@MainActor`: the closure is only ever
    // *called* on the main actor, but the relay itself is passed into
    // background work, so the reference crosses isolation even though the
    // invocation does not.
    private let deliver: @Sendable @MainActor (Payload) -> Void

    init(_ deliver: @escaping @Sendable @MainActor (Payload) -> Void) {
        self.deliver = deliver
    }

    /// Fire and forget.
    func send(_ payload: Payload) {
        Task { @MainActor [deliver] in deliver(payload) }
    }

    /// Awaits delivery — used where the caller must not run ahead of the UI,
    /// so that a batch is visibly merged before the next one starts.
    func sendAndWait(_ payload: Payload) async {
        await MainActor.run { [deliver] in deliver(payload) }
    }
}

// MARK: - Persistence

/// Reads and writes `.ua/knowledge-graph.json` and its sidecars.
///
/// The format is upstream's exactly, which is the whole point: a graph written
/// here opens in the Claude Code plugin's dashboard, and one written there opens
/// here with no conversion step.
enum GraphStore {
    /// Bumped whenever the deterministic pipeline starts producing a different
    /// graph for the same input.
    ///
    /// Without this the app reuses a cached graph forever, so a user who
    /// updates the app keeps whatever the old analyzer got wrong. That is not
    /// hypothetical: the jsconfig alias fix took one real project from 1 import
    /// edge to 44, and the cache happily served the 1-edge version until the
    /// user pressed Reanalyze — with nothing on screen suggesting they should.
    ///
    /// History:
    ///   1 — first release
    ///   2 — tsconfig/jsconfig "./" alias targets now resolve
    static let analyzerVersion = 2

    /// True when the cached graph predates the current analyzer.
    static func isStale(projectRoot: String) -> Bool {
        let stamp = (try? String(contentsOfFile: DataDirectory.analyzerStampPath(projectRoot),
                                 encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(stamp ?? "") != analyzerVersion
    }

    static func load(projectRoot: String) -> KnowledgeGraph? {
        let path = DataDirectory.graphPath(projectRoot)
        guard let data = ScanLimits.dataIfSmallEnough(path, limit: 256 * 1024 * 1024) else {
            return nil
        }
        // Foreign graphs go through the repairing validator rather than a
        // strict decode, so one malformed node cannot lose the whole file.
        return GraphSchema.validate(data).graph
    }

    static func save(_ graph: KnowledgeGraph, projectRoot: String) throws {
        try JSONFile.write(graph, to: DataDirectory.graphPath(projectRoot))
        try? "\(analyzerVersion)".write(
            toFile: DataDirectory.analyzerStampPath(projectRoot),
            atomically: true, encoding: .utf8
        )
        try JSONFile.write(
            AnalysisMeta(
                lastAnalyzedAt: ISO8601DateFormatter().string(from: Date()),
                gitCommitHash: graph.project.gitCommitHash,
                version: KnowledgeGraph.currentVersion,
                analyzedFiles: graph.nodes.filter { NodeType.fileLevel.contains($0.type) }.count,
                theme: nil
            ),
            to: DataDirectory.metaPath(projectRoot)
        )
    }
}
