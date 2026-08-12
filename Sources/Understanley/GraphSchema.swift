import Foundation

/// Loads a knowledge graph from untrusted JSON, repairing what it can.
///
/// Ported from upstream's `schema.ts`. Deliberately parses with
/// `JSONSerialization` rather than `Codable`: these files may have been written
/// by an older version, a different tool, or an LLM that improvised a field
/// name, and a strict decode throws away the entire graph over one bad node.
/// Instead the input goes through four tiers — sanitize, normalize, auto-fix,
/// drop — and every repair is recorded as a `GraphIssue` so the user can see
/// exactly what was changed on their behalf.
enum GraphSchema {
    struct Result: Sendable {
        var graph: KnowledgeGraph?
        var issues: [GraphIssue]

        var isValid: Bool { graph != nil }
    }

    // MARK: - Alias tables

    /// Node type spellings seen in the wild, mapped to the canonical name.
    static let nodeTypeAliases: [String: String] = [
        "func": "function", "fn": "function", "method": "function",
        "interface": "class", "struct": "class",
        "mod": "module", "pkg": "module", "package": "module",
        "container": "service", "deployment": "service", "pod": "service",
        "doc": "document", "readme": "document", "docs": "document",
        "job": "pipeline", "ci": "pipeline",
        "route": "endpoint", "api": "endpoint", "query": "endpoint", "mutation": "endpoint",
        "setting": "config", "env": "config", "configuration": "config",
        "infra": "resource", "infrastructure": "resource", "terraform": "resource",
        "migration": "table", "database": "table", "db": "table", "view": "table",
        "proto": "schema", "protobuf": "schema", "definition": "schema", "typedef": "schema",
        "business_domain": "domain",
        "business_flow": "flow", "business_process": "flow",
        "task": "step", "business_step": "step",
        "note": "article", "wiki_page": "article",
        "person": "entity", "actor": "entity", "organization": "entity",
        "tag": "topic", "category": "topic", "theme": "topic",
        "assertion": "claim", "decision": "claim", "thesis": "claim",
        "reference": "source", "raw": "source", "paper": "source",
    ]

    /// Aliases that only apply to design graphs. `page` means something
    /// different in a Figma file than in a wiki, so the mapping is keyed off
    /// the graph's `kind`.
    static let designNodeTypeAliases: [String: String] = [
        "frame": "screen", "artboard": "screen",
        "canvas": "page",
        "main_component": "component",
        "component_set": "componentSet", "variant_set": "componentSet",
        "componentset": "componentSet",
        "design_token": "token", "style": "token",
    ]

    static let nonDesignNodeTypeAliases: [String: String] = ["page": "article"]

    static let edgeTypeAliases: [String: String] = [
        "extends": "inherits",
        "invokes": "calls", "invoke": "calls",
        "uses": "depends_on", "requires": "depends_on",
        "relates_to": "related", "related_to": "related",
        "similar": "similar_to",
        "import": "imports", "export": "exports", "contain": "contains",
        "publish": "publishes", "subscribe": "subscribes",
        "describes": "documents", "documented_by": "documents",
        "creates": "provisions",
        "exposes": "serves", "listens": "serves",
        "deploys_to": "deploys", "migrates_to": "migrates", "routes_to": "routes",
        "triggers_on": "triggers", "fires": "triggers",
        "defines": "defines_schema",
        "has_flow": "contains_flow", "next_step": "flow_step",
        "interacts_with": "cross_domain",
        "references": "cites", "cites_source": "cites",
        "conflicts_with": "contradicts", "disagrees_with": "contradicts",
        "refines": "builds_on", "elaborates": "builds_on",
        "illustrates": "exemplifies", "example_of": "exemplifies",
        "belongs_to": "categorized_under", "tagged_with": "categorized_under",
        "written_by": "authored_by", "created_by": "authored_by",
    ]

    static let designEdgeTypeAliases: [String: String] = [
        "instantiates": "instance_of",
        "variant": "variant_of",
        "styled_by": "uses_token", "applies_token": "uses_token",
    ]

    static let nonDesignEdgeTypeAliases: [String: String] = ["instance_of": "exemplifies"]

    static let complexityAliases: [String: String] = [
        "low": "simple", "easy": "simple", "trivial": "simple", "basic": "simple",
        "medium": "moderate", "intermediate": "moderate", "mid": "moderate",
        "average": "moderate",
        "high": "complex", "hard": "complex", "difficult": "complex", "advanced": "complex",
    ]

    static let directionAliases: [String: String] = [
        "to": "forward", "outbound": "forward",
        "from": "backward", "inbound": "backward",
        "both": "bidirectional", "mutual": "bidirectional",
    ]

    // MARK: - Entry points

    static func validate(_ data: Data) -> Result {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return Result(graph: nil, issues: [
                GraphIssue(.fatal, .invalidCollection, "This file is not a valid JSON object.")
            ])
        }
        return validate(root)
    }

    static func validate(_ root: [String: Any]) -> Result {
        var issues: [GraphIssue] = []

        // ── Project metadata is the one genuinely required piece ──
        guard let projectRaw = root["project"] as? [String: Any],
              let name = projectRaw["name"] as? String, !name.isEmpty else {
            return Result(graph: nil, issues: [
                GraphIssue(.fatal, .missingField,
                           "Missing project metadata — this does not look like a knowledge graph.")
            ])
        }

        let kindRaw = (root["kind"] as? String)?.lowercased()
        let kind = kindRaw.flatMap(GraphKind.init(rawValue:))
        let isDesign = kind == .design

        let project = ProjectMeta(
            name: name,
            languages: (projectRaw["languages"] as? [String]) ?? [],
            frameworks: (projectRaw["frameworks"] as? [String]) ?? [],
            description: (projectRaw["description"] as? String) ?? "",
            analyzedAt: (projectRaw["analyzedAt"] as? String) ?? "",
            gitCommitHash: (projectRaw["gitCommitHash"] as? String) ?? ""
        )

        // ── Collections must be arrays when present ──
        for key in ["nodes", "edges", "layers", "tour"] {
            if let value = root[key], !(value is NSNull), !(value is [Any]) {
                return Result(graph: nil, issues: [
                    GraphIssue(.fatal, .invalidCollection, "\"\(key)\" must be a list when present.")
                ])
            }
        }

        // ── Nodes ──
        var nodes: [GraphNode] = []
        var nodeIds = Set<String>()
        for (index, raw) in ((root["nodes"] as? [[String: Any]]) ?? []).enumerated() {
            switch parseNode(raw, index: index, isDesign: isDesign, issues: &issues) {
            case .some(let node):
                guard nodeIds.insert(node.id).inserted else {
                    issues.append(GraphIssue(
                        .dropped, .invalidNode,
                        "Duplicate node id \"\(node.id)\" — the later one was removed.",
                        path: "nodes[\(index)]"
                    ))
                    continue
                }
                nodes.append(node)
            case .none:
                continue
            }
        }

        guard !nodes.isEmpty else {
            return Result(graph: nil, issues: issues + [
                GraphIssue(.fatal, .invalidNode, "No usable nodes found in this graph.")
            ])
        }

        // ── Edges ──
        var edges: [GraphEdge] = []
        var edgeKeys = Set<String>()
        for (index, raw) in ((root["edges"] as? [[String: Any]]) ?? []).enumerated() {
            guard let edge = parseEdge(raw, index: index, isDesign: isDesign, issues: &issues) else {
                continue
            }
            // Referential integrity. An edge pointing at a node that was
            // dropped above would render as a line to nowhere.
            if !nodeIds.contains(edge.source) {
                issues.append(GraphIssue(
                    .dropped, .invalidReference,
                    "Edge source \"\(edge.source)\" is not a node in this graph.",
                    path: "edges[\(index)].source"
                ))
                continue
            }
            if !nodeIds.contains(edge.target) {
                issues.append(GraphIssue(
                    .dropped, .invalidReference,
                    "Edge target \"\(edge.target)\" is not a node in this graph.",
                    path: "edges[\(index)].target"
                ))
                continue
            }
            guard edgeKeys.insert(edge.dedupeKey).inserted else { continue }
            edges.append(edge)
        }

        // ── Layers and tour: prune dangling references silently, since a
        //    pruned id is a display detail rather than lost information ──
        var layers: [Layer] = []
        for (index, raw) in ((root["layers"] as? [[String: Any]]) ?? []).enumerated() {
            guard let id = raw["id"] as? String ?? raw["name"] as? String,
                  let name = raw["name"] as? String else {
                issues.append(GraphIssue(.dropped, .invalidLayer,
                                         "Layer is missing an id or name.", path: "layers[\(index)]"))
                continue
            }
            // Upstream sometimes emits `nodes` instead of `nodeIds`, and
            // sometimes objects instead of id strings.
            let rawIds = (raw["nodeIds"] as? [Any]) ?? (raw["nodes"] as? [Any]) ?? []
            let ids = rawIds.compactMap { element -> String? in
                if let s = element as? String { return s }
                if let dict = element as? [String: Any] { return dict["id"] as? String }
                return nil
            }.filter { nodeIds.contains($0) }

            layers.append(Layer(
                id: id.hasPrefix("layer:") ? id
                    : "layer:" + name.lowercased().replacingOccurrences(of: " ", with: "-"),
                name: name,
                description: (raw["description"] as? String) ?? "",
                nodeIds: ids
            ))
        }

        var tour: [TourStep] = []
        for (index, raw) in ((root["tour"] as? [[String: Any]]) ?? []).enumerated() {
            guard let title = raw["title"] as? String else {
                issues.append(GraphIssue(.dropped, .invalidTourStep,
                                         "Tour step is missing a title.", path: "tour[\(index)]"))
                continue
            }
            let rawIds = (raw["nodeIds"] as? [String]) ?? (raw["nodesToInspect"] as? [String]) ?? []
            tour.append(TourStep(
                order: (raw["order"] as? Int) ?? (index + 1),
                title: title,
                description: (raw["description"] as? String)
                    ?? (raw["whyItMatters"] as? String) ?? "",
                nodeIds: rawIds.filter { nodeIds.contains($0) },
                languageLesson: raw["languageLesson"] as? String
            ))
        }
        tour.sort { $0.order < $1.order }

        let graph = KnowledgeGraph(
            version: (root["version"] as? String) ?? KnowledgeGraph.currentVersion,
            kind: kind,
            project: project,
            nodes: nodes,
            edges: edges,
            layers: layers,
            tour: tour
        )
        return Result(graph: graph, issues: issues)
    }

    // MARK: - Item parsing

    private static func parseNode(
        _ raw: [String: Any], index: Int, isDesign: Bool, issues: inout [GraphIssue]
    ) -> GraphNode? {
        guard let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
            issues.append(GraphIssue(.dropped, .invalidNode,
                                     "Node has no id.", path: "nodes[\(index)]"))
            return nil
        }
        let label = (raw["name"] as? String) ?? id

        // Type, via aliases, defaulting to `file`.
        var typeString = ((raw["type"] as? String) ?? "").lowercased()
        if typeString.isEmpty {
            issues.append(GraphIssue(.autoCorrected, .missingField,
                                     "Node \"\(label)\" had no type; treated as a file.",
                                     path: "nodes[\(index)].type"))
            typeString = "file"
        }
        var type = NodeType(rawValue: typeString)
        if type == nil {
            let table = isDesign ? designNodeTypeAliases : nonDesignNodeTypeAliases
            if let mapped = table[typeString] ?? nodeTypeAliases[typeString],
               let resolved = NodeType(rawValue: mapped) {
                issues.append(GraphIssue(.autoCorrected, .alias,
                                         "Node \"\(label)\" used type \"\(typeString)\"; read as \"\(mapped)\".",
                                         path: "nodes[\(index)].type"))
                type = resolved
            }
        }
        guard let nodeType = type else {
            issues.append(GraphIssue(.dropped, .invalidNode,
                                     "Node \"\(label)\" has unknown type \"\(typeString)\".",
                                     path: "nodes[\(index)].type"))
            return nil
        }

        // Complexity, via aliases and numeric buckets.
        var complexity = Complexity.moderate
        if let value = raw["complexity"] as? String {
            let lowered = value.lowercased().trimmingCharacters(in: .whitespaces)
            if let parsed = Complexity(rawValue: lowered) {
                complexity = parsed
            } else if let mapped = complexityAliases[lowered], let parsed = Complexity(rawValue: mapped) {
                complexity = parsed
                issues.append(GraphIssue(.autoCorrected, .alias,
                                         "Node \"\(label)\" used complexity \"\(value)\"; read as \"\(mapped)\".",
                                         path: "nodes[\(index)].complexity"))
            }
        } else if let number = raw["complexity"] as? NSNumber {
            let n = number.intValue
            complexity = n <= 3 ? .simple : (n <= 6 ? .moderate : .complex)
            issues.append(GraphIssue(.autoCorrected, .typeCoercion,
                                     "Node \"\(label)\" had a numeric complexity; read as \"\(complexity.rawValue)\".",
                                     path: "nodes[\(index)].complexity"))
        }

        var summary = (raw["summary"] as? String) ?? ""
        if summary.isEmpty { summary = GraphNode.pendingSummary }

        var tags = (raw["tags"] as? [String]) ?? []
        if tags.isEmpty { tags = ["untagged"] }

        var lineRange: LineRange?
        if let pair = raw["lineRange"] as? [Int], pair.count == 2 {
            lineRange = LineRange(pair[0], pair[1])
        } else if let pair = raw["lineRange"] as? [NSNumber], pair.count == 2 {
            lineRange = LineRange(pair[0].intValue, pair[1].intValue)
        }

        return GraphNode(
            id: id,
            type: nodeType,
            name: label,
            filePath: raw["filePath"] as? String,
            lineRange: lineRange,
            summary: summary,
            tags: tags,
            complexity: complexity,
            languageNotes: raw["languageNotes"] as? String,
            domainMeta: decode(DomainMeta.self, from: raw["domainMeta"]),
            knowledgeMeta: decode(KnowledgeMeta.self, from: raw["knowledgeMeta"]),
            figmaMeta: decode(FigmaMeta.self, from: raw["figmaMeta"])
        )
    }

    private static func parseEdge(
        _ raw: [String: Any], index: Int, isDesign: Bool, issues: inout [GraphIssue]
    ) -> GraphEdge? {
        guard let source = raw["source"] as? String, let target = raw["target"] as? String,
              !source.isEmpty, !target.isEmpty else {
            issues.append(GraphIssue(.dropped, .invalidEdge,
                                     "Edge is missing a source or target.", path: "edges[\(index)]"))
            return nil
        }
        if source == target { return nil }

        var typeString = ((raw["type"] as? String) ?? "").lowercased()
        if typeString.isEmpty { typeString = "depends_on" }
        var type = EdgeType(rawValue: typeString)
        if type == nil {
            let table = isDesign ? designEdgeTypeAliases : nonDesignEdgeTypeAliases
            if let mapped = table[typeString] ?? edgeTypeAliases[typeString],
               let resolved = EdgeType(rawValue: mapped) {
                issues.append(GraphIssue(.autoCorrected, .alias,
                                         "Edge used type \"\(typeString)\"; read as \"\(mapped)\".",
                                         path: "edges[\(index)].type"))
                type = resolved
            }
        }
        guard let edgeType = type else {
            issues.append(GraphIssue(.dropped, .invalidEdge,
                                     "Edge has unknown type \"\(typeString)\".",
                                     path: "edges[\(index)].type"))
            return nil
        }

        var direction = EdgeDirection.forward
        if let value = (raw["direction"] as? String)?.lowercased() {
            if let parsed = EdgeDirection(rawValue: value) {
                direction = parsed
            } else if let mapped = directionAliases[value], let parsed = EdgeDirection(rawValue: mapped) {
                direction = parsed
            }
        }

        var weight = edgeType.canonicalWeight
        if let number = raw["weight"] as? NSNumber {
            weight = number.doubleValue
        } else if let text = raw["weight"] as? String, let parsed = Double(text) {
            weight = parsed
            issues.append(GraphIssue(.autoCorrected, .typeCoercion,
                                     "Edge weight was text; read as \(parsed).",
                                     path: "edges[\(index)].weight"))
        }
        if weight < 0 || weight > 1 {
            let clamped = min(1, max(0, weight))
            issues.append(GraphIssue(.autoCorrected, .outOfRange,
                                     "Edge weight \(weight) is outside 0–1; clamped to \(clamped).",
                                     path: "edges[\(index)].weight"))
            weight = clamped
        }

        return GraphEdge(source: source, target: target, type: edgeType,
                         direction: direction, description: raw["description"] as? String,
                         weight: weight)
    }

    /// Re-encodes a loose dictionary through `Codable` for the optional
    /// metadata blocks, where an exact shape is not worth hand-parsing.
    private static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}
