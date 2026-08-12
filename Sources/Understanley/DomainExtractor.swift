import Foundation

/// Derives the business domains a codebase serves, from the graph it already has.
///
/// The port of `/understand-domain`. Every other view answers a structural
/// question — what imports what, what lives where. This one answers "where does
/// refund logic live", which no amount of static analysis can determine: the
/// word *refund* may appear in no filename at all.
///
/// So it is the one pass that genuinely needs a model, and it is given the graph
/// rather than the source. Layers, file paths, exported names and existing
/// summaries carry almost all of the signal, cost a fraction of the tokens, and
/// keep the work bounded on a large project.
///
/// Output is three node types and three edge types that already exist in the
/// schema, so a domain graph written here opens in the upstream dashboard:
///
///     domain --contains_flow--> flow --flow_step--> step
///     domain --cross_domain--> domain
struct DomainExtractor: Sendable {
    private let provider: any LLMProvider
    private let diagnostics: DiagnosticsCollector
    private let outputLanguage: String?

    init(provider: any LLMProvider, diagnostics: DiagnosticsCollector,
         outputLanguage: String? = nil) {
        self.provider = provider
        self.diagnostics = diagnostics
        self.outputLanguage = outputLanguage
    }

    struct Progress: Sendable {
        var message: String
        var domains: Int
    }

    /// A domain and its flows, as the model returned them.
    struct Domain: Sendable {
        var name: String
        var summary: String
        /// Ids of graph nodes that implement this domain.
        var nodeIds: [String]
        var flows: [Flow]
    }

    struct Flow: Sendable {
        var name: String
        var summary: String
        var steps: [Step]
    }

    struct Step: Sendable {
        var name: String
        var summary: String
        /// The graph node this step happens in, when the model named one.
        var nodeId: String?
    }

    /// Runs the extraction and returns the nodes and edges to merge in.
    ///
    /// Returns an empty result rather than throwing when the model declines or
    /// returns nothing usable: a failed domain pass must leave the existing
    /// graph exactly as it was.
    func run(
        graph: KnowledgeGraph,
        onProgress: @Sendable @escaping (Progress) async -> Void
    ) async -> (nodes: [GraphNode], edges: [GraphEdge]) {
        await onProgress(Progress(message: "Reading the shape of the project…", domains: 0))

        let request = LLMRequest(
            system: Prompts.domainSystem(language: outputLanguage),
            user: Prompts.domainUser(graph: graph),
            maxTokens: 4000
        )

        let response: LLMResponse
        do {
            response = try await provider.send(request)
        } catch {
            await diagnostics.add(
                .autoCorrected, .providerFailure,
                "Domains could not be derived: \(error.localizedDescription)"
            )
            await onProgress(Progress(message: error.localizedDescription, domains: 0))
            return ([], [])
        }

        let domains = Self.parse(response.text)
        guard !domains.isEmpty else {
            await diagnostics.add(
                .autoCorrected, .providerFailure,
                "The model returned no usable domains for this project."
            )
            await onProgress(Progress(message: "No domains were identified.", domains: 0))
            return ([], [])
        }

        let built = build(from: domains, graph: graph)
        await onProgress(Progress(
            message: "Found \(domains.count) domain\(domains.count == 1 ? "" : "s").",
            domains: domains.count
        ))
        return built
    }

    // MARK: - Building graph elements

    /// Turns parsed domains into schema nodes and edges.
    ///
    /// Every referenced node id is checked against the real graph. A model that
    /// invents `file:src/billing.ts` for a project that has no such file would
    /// otherwise produce dangling edges, which the schema validator drops later
    /// and which would make the domain view quietly wrong in the meantime.
    private func build(
        from domains: [Domain], graph: KnowledgeGraph
    ) -> (nodes: [GraphNode], edges: [GraphEdge]) {
        let known = Set(graph.nodes.map(\.id))
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []

        for domain in domains {
            let domainID = "domain:" + Self.slug(domain.name)
            nodes.append(GraphNode(
                id: domainID, type: .domain, name: domain.name,
                summary: domain.summary, tags: ["domain"]
            ))

            // Link the domain to the code that implements it.
            for nodeID in domain.nodeIds where known.contains(nodeID) {
                edges.append(GraphEdge(source: domainID, target: nodeID,
                                       type: .depends_on, weight: 0.6))
            }

            for flow in domain.flows {
                let flowID = domainID + ":flow:" + Self.slug(flow.name)
                nodes.append(GraphNode(
                    id: flowID, type: .flow, name: flow.name,
                    summary: flow.summary, tags: ["flow"]
                ))
                edges.append(GraphEdge(source: domainID, target: flowID,
                                       type: .contains_flow, weight: 1.0))

                var previous: String?
                for (position, step) in flow.steps.enumerated() {
                    let stepID = flowID + ":step:\(position)-" + Self.slug(step.name)
                    nodes.append(GraphNode(
                        id: stepID, type: .step, name: step.name,
                        summary: step.summary, tags: ["step"]
                    ))
                    // The flow owns its steps; the steps chain to each other, so
                    // the order a reader needs is in the graph rather than only
                    // in the numbering.
                    edges.append(GraphEdge(source: flowID, target: stepID,
                                           type: .flow_step, weight: 0.9))
                    if let previous {
                        edges.append(GraphEdge(source: previous, target: stepID,
                                               type: .flow_step, weight: 0.7))
                    }
                    previous = stepID

                    if let nodeID = step.nodeId, known.contains(nodeID) {
                        edges.append(GraphEdge(source: stepID, target: nodeID,
                                               type: .depends_on, weight: 0.5))
                    }
                }
            }
        }

        // Two domains that share implementation code are related, and saying so
        // is most of what makes the view useful — it is where the coupling is.
        var owners: [String: Set<String>] = [:]
        for domain in domains {
            let domainID = "domain:" + Self.slug(domain.name)
            for nodeID in domain.nodeIds where known.contains(nodeID) {
                owners[nodeID, default: []].insert(domainID)
            }
        }
        var crossed: Set<String> = []
        for (_, sharers) in owners where sharers.count > 1 {
            let sorted = sharers.sorted()
            for a in 0..<sorted.count {
                for b in (a + 1)..<sorted.count {
                    let key = sorted[a] + "|" + sorted[b]
                    guard crossed.insert(key).inserted else { continue }
                    edges.append(GraphEdge(source: sorted[a], target: sorted[b],
                                           type: .cross_domain, weight: 0.6))
                }
            }
        }

        return (nodes, edges)
    }

    // MARK: - Parsing

    /// Reads the model's JSON, keeping whatever is well-formed.
    ///
    /// Tolerant on purpose: a model that gets nine domains right and malforms
    /// the tenth should cost the tenth, not the pass.
    static func parse(_ text: String) -> [Domain] {
        guard let root = Prompts.extractJSONObject(from: text),
              let rawDomains = root["domains"] as? [[String: Any]]
        else { return [] }

        var out: [Domain] = []
        for raw in rawDomains.prefix(ScanLimits.maxDomains) {
            guard let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }

            let flows = (raw["flows"] as? [[String: Any]] ?? [])
                .prefix(ScanLimits.maxFlowsPerDomain)
                .compactMap { rawFlow -> Flow? in
                    guard let flowName = (rawFlow["name"] as? String)?
                        .trimmingCharacters(in: .whitespaces), !flowName.isEmpty else { return nil }
                    let steps = (rawFlow["steps"] as? [[String: Any]] ?? [])
                        .prefix(ScanLimits.maxStepsPerFlow)
                        .compactMap { rawStep -> Step? in
                            guard let stepName = (rawStep["name"] as? String)?
                                .trimmingCharacters(in: .whitespaces),
                                  !stepName.isEmpty else { return nil }
                            return Step(
                                name: ScanLimits.clamp(stepName, 80),
                                summary: ScanLimits.clamp(rawStep["summary"] as? String ?? "", 300),
                                nodeId: rawStep["nodeId"] as? String
                            )
                        }
                    return Flow(
                        name: ScanLimits.clamp(flowName, 80),
                        summary: ScanLimits.clamp(rawFlow["summary"] as? String ?? "", 300),
                        steps: Array(steps)
                    )
                }

            out.append(Domain(
                name: ScanLimits.clamp(name, 80),
                summary: ScanLimits.clamp(raw["summary"] as? String ?? "", 400),
                nodeIds: (raw["nodeIds"] as? [String] ?? []).prefix(40).map { $0 },
                flows: Array(flows)
            ))
        }
        return out
    }

    /// Stable, filesystem-safe identifier fragment.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "domain" : String(out.prefix(60))
    }
}
