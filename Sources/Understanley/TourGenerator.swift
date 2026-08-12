import Foundation

/// Builds a guided walkthrough of the codebase.
///
/// Upstream hands this entirely to an LLM. Here the *ordering* is derived
/// deterministically — from the entry point outward, then layer by layer in
/// dependency order, picking the best-connected node in each — and only the
/// prose is left for enrichment to improve. That way a tour exists on a graph
/// that has never seen a model, and enrichment rewrites descriptions rather
/// than inventing structure.
enum TourGenerator {
    /// Canonical reading order. A newcomer wants the shape of the system
    /// before its plumbing: what it exposes, what it decides, what it stores,
    /// and only then how it is wired and shipped.
    private static let layerOrder = [
        "Core",
        "API Layer",
        "UI Layer",
        "Service Layer",
        "Data Layer",
        "Middleware Layer",
        "Background Tasks",
        "External Services",
        "Utility Layer",
        "Configuration Layer",
        "Test Layer",
    ]

    private static let maxSteps = 9
    private static let nodesPerStep = 4

    static func generate(
        nodes: [GraphNode],
        edges: [GraphEdge],
        layers: [Layer],
        entryPoint: String?
    ) -> [TourStep] {
        guard !nodes.isEmpty else { return [] }

        let nodesById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var degree: [String: Int] = [:]
        for edge in edges {
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
        }

        var steps: [TourStep] = []
        var used = Set<String>()

        // ── Step 1: orientation ──
        var openers: [String] = []
        if let readme = nodes.first(where: {
            $0.type == .document && PosixPath.basename($0.filePath ?? "").lowercased().hasPrefix("readme")
        }) {
            openers.append(readme.id)
        }
        if let entryPoint, let entryNode = nodes.first(where: { $0.filePath == entryPoint }) {
            openers.append(entryNode.id)
        }
        if openers.isEmpty {
            // No README and no conventional entry point: open on whatever the
            // rest of the system leans on most.
            if let hub = nodes
                .filter({ NodeType.fileLevel.contains($0.type) })
                .max(by: { (degree[$0.id] ?? 0) < (degree[$1.id] ?? 0) }) {
                openers.append(hub.id)
            }
        }
        if !openers.isEmpty {
            used.formUnion(openers)
            steps.append(TourStep(
                order: 1,
                title: "Start here",
                description: openers.count > 1
                    ? "The project's own introduction, and the file the program actually starts from."
                    : "Where this project introduces itself.",
                nodeIds: openers
            ))
        }

        // ── One step per layer, in reading order ──
        let ordered = layers.sorted { a, b in
            let ai = layerOrder.firstIndex(of: a.name) ?? layerOrder.count
            let bi = layerOrder.firstIndex(of: b.name) ?? layerOrder.count
            if ai != bi { return ai < bi }
            return compareUTF16(a.name, b.name) == .orderedAscending
        }

        for layer in ordered {
            guard steps.count < maxSteps else { break }
            // The test layer is worth a step only when nothing else is left to
            // say — it teaches the least about how the system works.
            if layer.name == "Test Layer", steps.count > 2 { continue }

            let candidates = layer.nodeIds
                .filter { !used.contains($0) }
                .compactMap { nodesById[$0] }
                .filter { NodeType.fileLevel.contains($0.type) }
                .sorted {
                    let da = degree[$0.id] ?? 0
                    let db = degree[$1.id] ?? 0
                    if da != db { return da > db }
                    return compareUTF16($0.id, $1.id) == .orderedAscending
                }
                .prefix(nodesPerStep)

            guard !candidates.isEmpty else { continue }
            let ids = candidates.map(\.id)
            used.formUnion(ids)

            steps.append(TourStep(
                order: steps.count + 1,
                title: layer.name,
                description: description(for: layer, nodeCount: layer.nodeIds.count),
                nodeIds: ids
            ))
        }

        return steps
    }

    private static func description(for layer: Layer, nodeCount: Int) -> String {
        let base = layer.description.isEmpty
            ? "Files grouped under \(layer.name)."
            : layer.description + "."
        let scale = nodeCount == 1 ? "1 file" : "\(nodeCount) files"
        return "\(base) \(scale) in this layer; the most connected are shown here."
    }
}
