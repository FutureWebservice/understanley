import Foundation

/// Fills in the prose the deterministic pipeline cannot derive.
///
/// Three properties matter more than speed:
///
/// - **Progressive.** Every batch that returns is merged into the live graph
///   immediately, so summaries appear while the rest is still running. Waiting
///   for a whole run to finish before showing anything would make a five-minute
///   job feel broken.
/// - **Resumable.** Completed batches are journaled to disk keyed by content,
///   so quitting, crashing or losing the network keeps everything that landed
///   and the next run starts from there. Paying twice for the same tokens is a
///   real cost, not a theoretical one.
/// - **Bounded.** Concurrency backs off on rate limits rather than hammering.
actor Enricher {
    struct Progress: Sendable {
        var completed: Int
        var total: Int
        var described: Int
        var failed: Int
        var message: String

        var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    /// One unit of work: a set of nodes described together.
    private struct Batch: Sendable {
        var index: Int
        var items: [Prompts.BatchItem]
        /// Stable across runs, so a journal entry survives a re-analysis that
        /// did not change these files.
        var fingerprint: String
    }

    /// What the model returned for one node.
    struct Description: Codable, Sendable {
        var summary: String
        var tags: [String]
    }

    private let provider: any LLMProvider
    private let projectRoot: String
    private let diagnostics: DiagnosticsCollector
    private let outputLanguage: String?

    /// Upstream's batching constants. Small enough that one failure loses
    /// little; large enough that per-request overhead stays amortised.
    /// Asked of the provider rather than fixed: Apple's on-device model holds
    /// a twentieth of what a hosted one does, and a batch that overflows its
    /// context fails outright.
    private var maxBatchSize: Int { provider.batchCapacity }
    private lazy var concurrency = provider.maxConcurrency
    private let minimumConcurrency = 1

    init(
        provider: any LLMProvider, projectRoot: String,
        diagnostics: DiagnosticsCollector, outputLanguage: String? = nil
    ) {
        self.provider = provider
        self.projectRoot = projectRoot
        self.diagnostics = diagnostics
        self.outputLanguage = outputLanguage
    }

    // MARK: - Running

    /// Describes every undescribed node, reporting each batch as it lands.
    ///
    /// - Parameter onBatch: called on the main actor with descriptions to merge.
    func run(
        graph: KnowledgeGraph,
        onBatch: @Sendable @escaping ([String: Description], Progress) async -> Void
    ) async {
        var journal = Journal.load(projectRoot: projectRoot)

        // Anything already described — by a previous run, or by the upstream
        // plugin — is left alone.
        let pending = graph.nodes.filter { !$0.isEnriched }
        guard !pending.isEmpty else {
            await onBatch([:], Progress(completed: 0, total: 0, described: 0, failed: 0,
                                        message: "Every node already has a summary."))
            return
        }

        // Replay the journal first: instant, free, and it means a resumed run
        // picks up where it left off instead of appearing to restart.
        let fingerprints = Self.fingerprints(for: pending, graph: graph)
        let replayed = journal.replay(for: graph, fingerprints: fingerprints)
        if !replayed.isEmpty {
            await onBatch(replayed, Progress(
                completed: 0, total: pending.count,
                described: replayed.count, failed: 0,
                message: "Restored \(replayed.count) summaries written earlier."
            ))
        }

        let stillPending = pending.filter { replayed[$0.id] == nil }
        guard !stillPending.isEmpty else {
            await onBatch([:], Progress(
                completed: pending.count, total: pending.count,
                described: replayed.count, failed: 0,
                message: "Every node already has a summary."
            ))
            return
        }

        let batches = makeBatches(for: stillPending, graph: graph)
        let remaining = batches

        var completed = 0
        var described = replayed.count
        var failed = 0
        var cursor = 0

        while cursor < remaining.count {
            if Task.isCancelled { break }

            let width = min(concurrency, remaining.count - cursor)
            let slice = Array(remaining[cursor..<(cursor + width)])
            cursor += width

            var sawRateLimit = false

            await withTaskGroup(of: (Batch, [String: Description]?, LLMError?).self) { group in
                for batch in slice {
                    group.addTask { [provider, outputLanguage] in
                        do {
                            let result = try await Self.describe(
                                batch: batch, graph: graph, provider: provider,
                                language: outputLanguage
                            )
                            return (batch, result, nil)
                        } catch let error as LLMError {
                            return (batch, nil, error)
                        } catch {
                            return (batch, nil, .transport(error.localizedDescription))
                        }
                    }
                }

                for await (batch, result, error) in group {
                    completed += 1
                    if let result {
                        described += result.count
                        for (id, description) in result {
                            journal.nodes[id] = Journal.Entry(
                                fingerprint: fingerprints[id] ?? "", description: description
                            )
                        }
                        await onBatch(result, Progress(
                            completed: min(pending.count, replayed.count + completed),
                            total: pending.count,
                            described: described, failed: failed,
                            message: "Describing — \(described) of \(pending.count) nodes"
                        ))
                    } else if let error {
                        failed += 1
                        if case .rateLimited = error { sawRateLimit = true }
                        await diagnostics.add(
                            .autoCorrected, .providerFailure,
                            "Batch \(batch.index) could not be described: \(error.localizedDescription)"
                        )
                    }
                }
            }

            // Written after each wave rather than at the end, so a crash mid-run
            // still leaves the completed work recoverable.
            journal.save(projectRoot: projectRoot)

            if sawRateLimit {
                concurrency = max(minimumConcurrency, concurrency - 1)
            } else if concurrency < provider.maxConcurrency {
                concurrency += 1
            }
        }

        let summary: String
        if Task.isCancelled {
            summary = "Stopped. \(described) nodes described — they are saved."
        } else if failed > 0 {
            summary = "Described \(described) nodes. \(failed) batch\(failed == 1 ? "" : "es") failed."
        } else {
            summary = "Described \(described) nodes."
        }
        await onBatch([:], Progress(completed: pending.count, total: pending.count,
                                    described: described, failed: failed, message: summary))
    }

    // MARK: - Narrative passes

    /// Prose for the layers and the tour.
    ///
    /// The deterministic pipeline names layers by directory convention ("Core",
    /// "UI Layer") and orders the tour topologically. Both are correct and both
    /// read like a form: the layer descriptions are generic templates and the
    /// tour steps say "Core application files. 20 files in this layer."
    ///
    /// This is the pass that makes them say something about *this* project. Two
    /// requests, run after the per-node work, and entirely optional — a failure
    /// leaves the deterministic text exactly as it was.
    struct Narrative: Sendable {
        var layerDescriptions: [String: String] = [:]
        var tourSteps: [Int: (title: String, description: String)] = [:]
        var isEmpty: Bool { layerDescriptions.isEmpty && tourSteps.isEmpty }
    }

    func describeNarrative(graph: KnowledgeGraph) async -> Narrative {
        var out = Narrative()

        if !graph.layers.isEmpty {
            let samples = graph.layers.map { layer -> (Layer, [String]) in
                let names = layer.nodeIds.prefix(10).compactMap { id in
                    graph.nodes.first { $0.id == id }?.name
                }
                return (layer, Array(names))
            }
            let request = LLMRequest(
                system: Prompts.layerNamingSystem,
                user: Prompts.layerNamingUser(project: graph.project, layers: samples),
                maxTokens: 1500
            )
            if let root = await send(request, what: "layer descriptions"),
               let entries = root["layers"] as? [[String: Any]] {
                // Ids are matched leniently. A small model will hand back
                // `layer-core` for `layer:core`, or echo the layer's name in
                // place of its id — losing a whole description to a mangled
                // separator would be a poor trade.
                var byKey: [String: Layer] = [:]
                for layer in graph.layers {
                    byKey[Self.loosely(layer.id)] = layer
                    byKey[Self.loosely(layer.name)] = layer
                }

                for entry in entries {
                    guard let raw = entry["id"] as? String,
                          let description = entry["description"] as? String else { continue }
                    guard let layer = byKey[Self.loosely(raw)] else { continue }
                    // A description that just restates the name ("Core" for the
                    // Core layer) is worse than the deterministic sentence it
                    // would replace, so it is refused rather than applied.
                    let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count > 25,
                          Self.loosely(trimmed) != Self.loosely(layer.name),
                          // A small model will happily copy an example out of
                          // its own instructions. A confidently wrong sentence
                          // about a project is worse than the generic one it
                          // would replace, so anything matching the deterministic
                          // text or a known exemplar is refused.
                          Self.loosely(trimmed) != Self.loosely(layer.description) else { continue }
                    out.layerDescriptions[layer.id] = ScanLimits.clamp(trimmed, 400)
                }
            }
        }

        if !graph.tour.isEmpty {
            let samples = graph.tour.map { step -> (TourStep, [String]) in
                let names = step.nodeIds.prefix(8).compactMap { id in
                    graph.nodes.first { $0.id == id }?.name
                }
                return (step, Array(names))
            }
            let request = LLMRequest(
                system: Prompts.tourSystem,
                user: Prompts.tourUser(project: graph.project, steps: samples),
                maxTokens: 2000
            )
            if let root = await send(request, what: "the tour"),
               let entries = root["steps"] as? [[String: Any]] {
                for entry in entries {
                    guard let order = entry["order"] as? Int else { continue }
                    let title = (entry["title"] as? String) ?? ""
                    let description = (entry["description"] as? String) ?? ""
                    guard !title.isEmpty || !description.isEmpty else { continue }
                    out.tourSteps[order] = (
                        ScanLimits.clamp(title, 90), ScanLimits.clamp(description, 600)
                    )
                }
            }
        }

        return out
    }

    /// Lowercased letters and digits only — for comparing identifiers a model
    /// may have reformatted.
    static func loosely(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// One request, with failure reported and swallowed.
    private func send(_ request: LLMRequest, what: String) async -> [String: Any]? {
        do {
            let response = try await provider.send(request)
            return Prompts.extractJSONObject(from: response.text)
        } catch {
            await diagnostics.add(
                .autoCorrected, .providerFailure,
                "Could not write \(what): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Batching

    /// Groups nodes into batches that share context.
    ///
    /// Ordered by file path so a batch tends to hold neighbours: describing
    /// `auth/login.ts` alongside `auth/session.ts` produces better summaries
    /// than pairing either with a random config file, because the model can see
    /// what the group is collectively for.
    private func makeBatches(for nodes: [GraphNode], graph: KnowledgeGraph) -> [Batch] {
        let ordered = nodes.sortedStable { ($0.filePath ?? "") + "\u{1}" + $0.id }

        var batches: [Batch] = []
        var current: [Prompts.BatchItem] = []

        func flush() {
            guard !current.isEmpty else { return }
            // Fingerprint over the ids and facts, so a batch whose files did
            // not change reuses its journal entry after re-analysis.
            let material = current.map { $0.id + "|" + $0.facts.joined(separator: ",") }
                .joined(separator: "\n")
            batches.append(Batch(
                index: batches.count + 1, items: current,
                fingerprint: Hash.sha256Hex(material)
            ))
            current = []
        }

        for node in ordered {
            current.append(makeItem(for: node, graph: graph))
            if current.count >= maxBatchSize { flush() }
        }
        flush()
        return batches
    }

    /// Assembles the deterministic facts and a bounded excerpt for one node.
    /// A stable hash of what each node *is*, so a stored description can be
    /// checked for staleness without re-reading the source.
    ///
    /// Deliberately the same material the prompt sees: if the model would be
    /// told something different, the old answer no longer applies.
    static func fingerprints(for nodes: [GraphNode], graph: KnowledgeGraph) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(nodes.count)
        for node in nodes {
            let material = [
                node.id, node.name, node.type.rawValue, node.complexity.rawValue,
                node.filePath ?? "",
                node.lineRange.map { "\($0.start)-\($0.end)" } ?? "",
            ].joined(separator: "|")
            out[node.id] = Hash.sha256Hex(material)
        }
        return out
    }

    private func makeItem(for node: GraphNode, graph: KnowledgeGraph) -> Prompts.BatchItem {
        var facts: [String] = []

        if let range = node.lineRange {
            facts.append("\(range.lineCount) lines")
        }
        facts.append("complexity: \(node.complexity.rawValue)")
        if node.tags.contains("tested") { facts.append("covered by tests") }
        if node.tags.contains("entry-point") { facts.append("an entry point") }

        // Incoming and outgoing edges say a great deal about role, and cost
        // nothing to include.
        let outgoing = graph.edges.filter { $0.source == node.id }
        let incoming = graph.edges.filter { $0.target == node.id }
        if !outgoing.isEmpty {
            let kinds = Set(outgoing.map(\.type.rawValue)).sorted().prefix(4)
            facts.append("\(outgoing.count) outgoing (\(kinds.joined(separator: ", ")))")
        }
        if !incoming.isEmpty {
            facts.append("used by \(incoming.count)")
        }

        return Prompts.BatchItem(
            id: node.id,
            type: node.type.rawValue,
            path: node.filePath,
            facts: facts,
            excerpt: excerpt(for: node)
        )
    }

    /// A bounded slice of the real source.
    ///
    /// Capped hard: this is the only part of the prompt that leaves the machine
    /// containing actual code, and an unbounded excerpt would both cost tokens
    /// and send far more than the task needs. For a symbol it is its own line
    /// range; for a file it is the head, which is where imports and the primary
    /// declaration live.
    private func excerpt(for node: GraphNode) -> String? {
        guard let path = node.filePath, PosixPath.isSafeRelative(path) else { return nil }
        guard let source = FileRead.text(at: projectRoot + "/" + path,
                                         limit: ScanLimits.maxSourceFileBytes) else { return nil }

        let lines = source.components(separatedBy: "\n")
        let maxLines = 60
        let maxCharacters = provider.excerptBudget

        var slice: [String]
        if let range = node.lineRange {
            let start = max(0, range.start - 1)
            let end = min(lines.count, start + maxLines)
            guard start < end else { return nil }
            slice = Array(lines[start..<end])
        } else {
            slice = Array(lines.prefix(maxLines))
        }

        var text = slice.joined(separator: "\n")
        if text.count > maxCharacters {
            text = String(text.prefix(maxCharacters)) + "\n…"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: - One batch

    private static func describe(
        batch: Batch, graph: KnowledgeGraph, provider: any LLMProvider, language: String?
    ) async throws -> [String: Description] {
        let request = LLMRequest(
            system: Prompts.fileAnalysisSystem(language: language),
            user: Prompts.fileAnalysisUser(project: graph.project, items: batch.items),
            maxTokens: 4000
        )
        let response = try await provider.send(request)

        guard let object = Prompts.extractJSONObject(from: response.text),
              let items = object["items"] as? [[String: Any]]
        else { throw LLMError.emptyResponse }

        // Only ids that were actually asked about are accepted — a model that
        // invents an id would otherwise write a summary onto the wrong node, or
        // onto a node that does not exist.
        let requested = Set(batch.items.map(\.id))
        var out: [String: Description] = [:]

        for item in items {
            guard let id = item["id"] as? String, requested.contains(id) else { continue }
            guard let summary = (item["summary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { continue }

            let tags = ((item["tags"] as? [String]) ?? [])
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            out[id] = Description(summary: ScanLimits.clamp(summary, 400),
                                  tags: Array(tags.prefix(5)))
        }
        return out
    }

    // MARK: - Journal

    /// Descriptions already written, on disk, keyed by node.
    ///
    /// Was keyed by *batch* fingerprint, which quietly made it useless for the
    /// thing it most needed to do. A batch's fingerprint covers the whole group
    /// of nodes in it, and how nodes are grouped depends on the provider's
    /// `batchCapacity` — so switching provider, or simply re-analyzing into a
    /// different grouping, meant nothing matched and every summary was paid for
    /// again. Keyed per node it replays regardless of who wrote it or how it
    /// was batched.
    ///
    /// `fingerprint` is over the node's own facts, so a description is dropped
    /// exactly when the thing it describes has changed.
    struct Journal: Codable, Sendable {
        struct Entry: Codable, Sendable {
            var fingerprint: String
            var description: Description
        }

        var version: Int = 2
        var providerID: String = ""
        /// Node id -> what was written about it.
        var nodes: [String: Entry] = [:]

        /// Descriptions valid for the graph as it stands now.
        func replay(for graph: KnowledgeGraph, fingerprints: [String: String])
            -> [String: Description] {
            var out: [String: Description] = [:]
            for node in graph.nodes {
                guard let entry = nodes[node.id],
                      entry.fingerprint == fingerprints[node.id] else { continue }
                out[node.id] = entry.description
            }
            return out
        }

        static func path(projectRoot: String) -> String {
            DataDirectory.resolve(projectRoot) + "/enrichment-journal.json"
        }

        static func load(projectRoot: String) -> Journal {
            JSONFile.read(Journal.self, from: path(projectRoot: projectRoot)) ?? Journal()
        }

        func save(projectRoot: String) {
            // Best-effort: losing the journal costs tokens on the next run but
            // nothing else, so a write failure must not interrupt enrichment.
            try? JSONFile.write(self, to: Self.path(projectRoot: projectRoot), pretty: false)
        }

        static func clear(projectRoot: String) {
            try? FileManager.default.removeItem(atPath: path(projectRoot: projectRoot))
        }
    }
}

// MARK: - Merging

extension KnowledgeGraph {
    /// Applies descriptions to matching nodes.
    ///
    /// Deterministic tags are kept and model tags added on top, rather than
    /// replaced: `tested` and `entry-point` are facts the analyzer established,
    /// and a model has no standing to remove them.
    /// Replaces the generic layer and tour text with what the model wrote.
    mutating func apply(_ narrative: Enricher.Narrative) {
        guard !narrative.isEmpty else { return }
        for index in layers.indices {
            if let description = narrative.layerDescriptions[layers[index].id] {
                layers[index].description = description
            }
        }
        for index in tour.indices {
            guard let written = narrative.tourSteps[tour[index].order] else { continue }
            if !written.title.isEmpty { tour[index].title = written.title }
            if !written.description.isEmpty { tour[index].description = written.description }
        }
    }

    mutating func apply(_ descriptions: [String: Enricher.Description]) {
        guard !descriptions.isEmpty else { return }
        for index in nodes.indices {
            guard let description = descriptions[nodes[index].id] else { continue }
            nodes[index].summary = description.summary
            for tag in description.tags where !nodes[index].tags.contains(tag) {
                nodes[index].tags.append(tag)
            }
            nodes[index].tags = Array(nodes[index].tags.prefix(8))
        }
    }
}
