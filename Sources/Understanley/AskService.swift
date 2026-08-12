import Foundation

/// Answers questions about the graph, and explains individual nodes.
///
/// The graph is what makes this worth doing at all. Without it, "how does the
/// payment flow work?" means dumping files at a model and hoping. With it, the
/// question can be answered from the specific subgraph that is actually
/// relevant — the node, what it depends on, what depends on it, and a bounded
/// slice of the real source.
///
/// The assembled context is always inspectable before it is sent. This is the
/// one feature that ships source code off the machine on a question the user
/// typed, so it should never be a mystery what went with it.
actor AskService {
    private let provider: any LLMProvider
    private let projectRoot: String

    init(provider: any LLMProvider, projectRoot: String) {
        self.provider = provider
        self.projectRoot = projectRoot
    }

    /// The material gathered for one question, ready to show or send.
    struct Context: Sendable {
        var nodeIDs: [String]
        var text: String
        /// Rough token estimate, so the user can see the size before sending.
        var approximateTokens: Int { max(1, text.count / 4) }
    }

    // MARK: - Explain a node

    /// Builds the context for explaining one node.
    ///
    /// Scope is the node, its immediate neighbours, and its own source. A
    /// deeper walk sounds more thorough and is not: it dilutes the prompt with
    /// files that merely happen to be two hops away, and the answer gets vaguer.
    func explainContext(
        nodeID: String, graph: KnowledgeGraph, arrays: GraphArrays
    ) -> Context? {
        guard let index = arrays.index(of: nodeID),
              let node = graph.nodes.first(where: { $0.id == nodeID }) else { return nil }

        var text = "PROJECT: \(graph.project.name) — \(graph.project.description)\n"
        if !graph.project.languages.isEmpty {
            text += "LANGUAGES: \(graph.project.languages.joined(separator: ", "))\n"
        }
        text += "\nEXPLAIN THIS:\n"
        text += describe(node, in: graph)

        if let excerpt = excerpt(for: node, maxLines: 160) {
            text += "\nITS SOURCE:\n```\n\(excerpt)\n```\n"
        }

        var included = [nodeID]
        let neighbours = Array(arrays.neighbours(of: index).prefix(24))
        if !neighbours.isEmpty {
            text += "\nWHAT IT CONNECTS TO:\n"
            for raw in neighbours {
                let neighbourID = arrays.ids[Int(raw)]
                guard let neighbour = graph.nodes.first(where: { $0.id == neighbourID }) else {
                    continue
                }
                included.append(neighbourID)
                let relation = relationship(between: nodeID, and: neighbourID, in: graph)
                text += "  - \(neighbour.name) (\(neighbour.type.rawValue))"
                if let relation { text += " — \(relation)" }
                if neighbour.isEnriched { text += ": \(neighbour.summary)" }
                text += "\n"
            }
        }

        return Context(nodeIDs: included, text: text)
    }

    // MARK: - Ask a question

    /// Builds the context for a free-form question.
    ///
    /// The nodes are chosen by the same search the user sees, then expanded by
    /// one hop — a question about "auth" is rarely answerable from the files
    /// with "auth" in the name alone.
    func askContext(
        question: String, graph: KnowledgeGraph, arrays: GraphArrays,
        engine: SearchEngine, budget: Int = 18
    ) -> Context {
        var text = "PROJECT: \(graph.project.name) — \(graph.project.description)\n"
        if !graph.project.languages.isEmpty {
            text += "LANGUAGES: \(graph.project.languages.joined(separator: ", "))\n"
        }
        if !graph.layers.isEmpty {
            text += "LAYERS: " + graph.layers.map { "\($0.name) (\($0.nodeIds.count))" }
                .joined(separator: ", ") + "\n"
        }

        let hits = engine.search(question, limit: budget)
        var selected: [Int] = hits.map(\.index)

        // One hop out from the best few matches. Without it, a question about a
        // behaviour gets only the files that happen to name it.
        var seen = Set(selected)
        for hit in hits.prefix(5) {
            for raw in arrays.neighbours(of: hit.index).prefix(6) {
                let neighbour = Int(raw)
                if seen.insert(neighbour).inserted { selected.append(neighbour) }
            }
        }
        selected = Array(selected.prefix(budget + 12))

        if selected.isEmpty {
            // Nothing matched, so fall back to the shape of the project: the
            // best-connected nodes describe it better than an arbitrary slice.
            selected = (0..<arrays.count)
                .sorted { arrays.degree[$0] > arrays.degree[$1] }
                .prefix(budget)
                .map { $0 }
        }

        text += "\nRELEVANT PARTS OF THE GRAPH:\n"
        var ids: [String] = []
        for index in selected {
            guard index < arrays.count else { continue }
            let id = arrays.ids[index]
            guard let node = graph.nodes.first(where: { $0.id == id }) else { continue }
            ids.append(id)
            text += describe(node, in: graph)
        }

        // Source only for the strongest matches — the budget is real, and a
        // ranked list of names plus a few excerpts answers better than twenty
        // truncated files.
        for hit in hits.prefix(4) {
            guard hit.index < arrays.count,
                  let node = graph.nodes.first(where: { $0.id == arrays.ids[hit.index] }),
                  let excerpt = excerpt(for: node, maxLines: 80) else { continue }
            text += "\nSOURCE OF \(node.name):\n```\n\(excerpt)\n```\n"
        }

        return Context(nodeIDs: ids, text: text)
    }

    // MARK: - Sending

    func explain(context: Context) async throws -> String {
        try await send(system: Self.explainSystem, user: context.text)
    }

    func answer(question: String, context: Context) async throws -> String {
        try await send(
            system: Self.askSystem,
            user: context.text + "\n\nQUESTION: \(question)\n"
        )
    }

    private func send(system: String, user: String) async throws -> String {
        let response = try await provider.send(
            LLMRequest(system: system, user: user, maxTokens: 2000, temperature: 0.3)
        )
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }

    // MARK: - Prompts

    static let explainSystem = """
        You are explaining one part of a codebase to a capable engineer who has not seen it.

        Say what it does, how it fits into the system around it, and anything about it that would \
        surprise a reader — an unusual responsibility, a dependency that runs the wrong way, a \
        name that does not match the behaviour. Three or four short paragraphs. No headings, no \
        bullet lists, no preamble.

        You are given the structure as fact: the connections listed are real and were derived by \
        static analysis, not guessed. Do not contradict them. If the source excerpt is truncated, \
        reason about what you can see and say plainly what you cannot.

        \(Prompts.untrustedContent)
        """

    static let askSystem = """
        You are answering a question about a codebase, using a knowledge graph of it.

        Answer directly and concretely, naming the specific files, functions and types involved. \
        Where you are inferring rather than reading, say so. If the context you were given does \
        not contain the answer, say that instead of constructing a plausible one — a confident \
        wrong answer about someone's own code is worse than no answer.

        The graph structure is fact, derived by static analysis. Source excerpts are truncated.

        \(Prompts.untrustedContent)
        """

    // MARK: - Context assembly

    private func describe(_ node: GraphNode, in graph: KnowledgeGraph) -> String {
        var line = "- \(node.name) [\(node.type.rawValue)]"
        if let path = node.filePath { line += " at \(path)" }
        if let range = node.lineRange { line += " lines \(range.start)–\(range.end)" }
        line += "\n"
        if node.isEnriched { line += "    \(node.summary)\n" }
        if !node.tags.isEmpty { line += "    tags: \(node.tags.joined(separator: ", "))\n" }
        return line
    }

    /// How two nodes are connected, phrased in the direction it holds.
    private func relationship(
        between source: String, and target: String, in graph: KnowledgeGraph
    ) -> String? {
        if let forward = graph.edges.first(where: { $0.source == source && $0.target == target }) {
            return forward.type.rawValue.replacingOccurrences(of: "_", with: " ")
        }
        if let backward = graph.edges.first(where: { $0.source == target && $0.target == source }) {
            return "is " + backward.type.rawValue.replacingOccurrences(of: "_", with: " ") + " by"
        }
        return nil
    }

    /// A bounded slice of real source, path-checked before reading.
    private func excerpt(for node: GraphNode, maxLines: Int) -> String? {
        guard let path = node.filePath, PosixPath.isSafeRelative(path) else { return nil }
        guard let source = FileRead.text(at: projectRoot + "/" + path,
                                         limit: ScanLimits.maxSourceFileBytes) else { return nil }

        let lines = source.components(separatedBy: "\n")
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
        let cap = maxLines * 60
        if text.count > cap { text = String(text.prefix(cap)) + "\n…" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
