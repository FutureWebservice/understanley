import Foundation

/// Turns scan results plus per-file structure into nodes and edges.
///
/// This is where the graph's shape is decided: which files become which node
/// type, which declarations are significant enough to get their own node, and
/// which relationships are real edges. Node id conventions and edge weights
/// match upstream exactly, because those ids are the graph's identity across
/// both tools.
struct GraphBuilder: Sendable {
    /// Everything known about one analyzed file.
    struct AnalyzedFile: Sendable {
        var file: ScannedFile
        var analysis: StructuralAnalysis
        /// Project-relative paths this file imports, already resolved.
        var resolvedImports: [String]
    }

    let diagnostics: DiagnosticsCollector

    // MARK: - Significance

    /// Whether a function deserves its own node.
    ///
    /// Upstream's filter: ten or more lines, or exported regardless of size.
    /// The size floor keeps one-line getters out of the graph; the export
    /// escape hatch keeps a small but public API surface in it.
    static func isSignificant(_ fn: FunctionInfo, exported: Bool) -> Bool {
        exported || fn.lineRange.lineCount >= 10
    }

    /// Whether a class deserves its own node: two or more methods, twenty or
    /// more lines, or exported.
    static func isSignificant(_ cls: ClassInfo, exported: Bool) -> Bool {
        exported || cls.methods.count >= 2 || cls.lineRange.lineCount >= 20
    }

    // MARK: - Node typing

    /// The node type a file becomes, from its category and its path.
    static func nodeType(for file: ScannedFile, analysis: StructuralAnalysis) -> NodeType {
        let posix = PosixPath.normalize(file.path)
        let base = PosixPath.basename(posix)
        let ext = PosixPath.fileExtension(posix)

        switch file.fileCategory {
        case .code, .script, .markup:
            return .file
        case .config:
            return .config
        case .docs:
            return .document
        case .infra:
            if posix.hasPrefix(".github/workflows/") || posix.hasPrefix(".circleci/")
                || base == ".gitlab-ci.yml" || base == "Jenkinsfile" {
                return .pipeline
            }
            if ext == ".tf" || ext == ".tfvars" || base == "Vagrantfile" {
                return .resource
            }
            if base == "Makefile" || base == "makefile" || base == "GNUmakefile" {
                return .pipeline
            }
            // Dockerfiles, compose files and K8s manifests all describe
            // something that runs.
            return .service
        case .data:
            switch ext {
            case ".graphql", ".gql", ".proto", ".prisma":
                return .schema
            case ".sql":
                // A migration that only alters tables still describes tables.
                return analysis.definitions.contains { $0.kind == "table" } ? .table : .schema
            default:
                if base.hasPrefix("openapi") || base.hasPrefix("swagger") { return .endpoint }
                return .schema
            }
        }
    }

    /// The edge type a non-code file uses to reference another file. Code files
    /// always emit `imports`; everything else says something more specific
    /// about *why* it points there.
    static func referenceEdgeType(from type: NodeType) -> EdgeType {
        switch type {
        case .config: return .configures
        case .document: return .documents
        case .service: return .deploys
        case .pipeline: return .triggers
        case .resource: return .provisions
        case .table: return .migrates
        case .schema: return .defines_schema
        case .endpoint: return .routes
        default: return .imports
        }
    }

    // MARK: - Build

    func build(scan: ScanResult, analyzed: [AnalyzedFile]) async -> (nodes: [GraphNode], edges: [GraphEdge]) {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var nodeIds = Set<String>()
        var edgeKeys = Set<String>()

        /// Symbol name → ids of the function/class nodes that define it. Used to
        /// turn unqualified call-graph entries into cross-file edges.
        var definitionsByName: [String: [String]] = [:]
        /// File path → node id, so an edge to a file can find its node whatever
        /// type that file became.
        var fileNodeIds: [String: String] = [:]
        var nodeTypesByPath: [String: NodeType] = [:]

        func addNode(_ node: GraphNode) {
            guard nodeIds.insert(node.id).inserted else { return }
            nodes.append(node)
        }

        func addEdge(_ edge: GraphEdge) {
            guard edge.source != edge.target else { return }
            guard edgeKeys.insert(edge.dedupeKey).inserted else { return }
            edges.append(edge)
        }

        // ── Pass 1: file nodes and their children ──
        for entry in analyzed {
            let file = entry.file
            let type = Self.nodeType(for: file, analysis: entry.analysis)
            let id = "\(type.idPrefix):\(file.path)"
            fileNodeIds[file.path] = id
            nodeTypesByPath[file.path] = type

            addNode(GraphNode(
                id: id,
                type: type,
                name: file.basename,
                filePath: file.path,
                summary: GraphNode.pendingSummary,
                tags: Tagger.tags(for: file, analysis: entry.analysis, nodeType: type),
                complexity: Self.complexity(ofLines: file.sizeLines, analysis: entry.analysis)
            ))

            let exportedNames = entry.analysis.exportedNames

            // Classes are created before functions so a method can be attached
            // to its own type rather than dangling off the file.
            var classIdsByName: [String: String] = [:]
            for cls in entry.analysis.classes {
                let exported = exportedNames.contains(cls.name)
                guard Self.isSignificant(cls, exported: exported) else { continue }
                let clsId = "class:\(file.path):\(cls.name)"
                addNode(GraphNode(
                    id: clsId,
                    type: .class,
                    name: cls.name,
                    filePath: file.path,
                    lineRange: cls.lineRange,
                    summary: GraphNode.pendingSummary,
                    tags: Tagger.tags(forClass: cls, exported: exported),
                    complexity: Self.complexity(ofLines: cls.lineRange.lineCount, analysis: nil)
                ))
                addEdge(GraphEdge(source: id, target: clsId, type: .contains))
                if exported {
                    addEdge(GraphEdge(source: id, target: clsId, type: .exports))
                }
                classIdsByName[cls.name] = clsId
                definitionsByName[cls.name, default: []].append(clsId)
            }

            // Functions, including methods (named `Type.method`).
            for fn in entry.analysis.functions {
                let shortName = Self.shortName(of: fn.name)
                let owner = Self.ownerTypeName(of: fn.name)
                // A method inherits its type's visibility: `User` being public
                // is what makes `User.save` reachable.
                let exported = exportedNames.contains(fn.name)
                    || exportedNames.contains(shortName)
                    || (owner.map { exportedNames.contains($0) } ?? false)
                guard Self.isSignificant(fn, exported: exported) else { continue }

                let fnId = "function:\(file.path):\(fn.name)"
                addNode(GraphNode(
                    id: fnId,
                    type: .function,
                    name: fn.name,
                    filePath: file.path,
                    lineRange: fn.lineRange,
                    summary: GraphNode.pendingSummary,
                    tags: Tagger.tags(forFunction: fn, exported: exported),
                    complexity: Self.complexity(ofLines: fn.lineRange.lineCount, analysis: nil)
                ))

                // Containment follows the source: a method belongs to its type,
                // a free function to its file.
                let container = owner.flatMap { classIdsByName[$0] } ?? id
                addEdge(GraphEdge(source: container, target: fnId, type: .contains))
                if exported {
                    addEdge(GraphEdge(source: id, target: fnId, type: .exports))
                }

                // Indexed under both spellings. Call sites write `save(...)`
                // even when the definition is `User.save`, so without the short
                // key no method call would ever resolve.
                definitionsByName[fn.name, default: []].append(fnId)
                if shortName != fn.name {
                    definitionsByName[shortName, default: []].append(fnId)
                }
            }

            // Non-code sub-file nodes.
            for service in entry.analysis.services {
                let serviceId = "service:\(file.path):\(service.name)"
                var tags = ["containerization", "infrastructure"]
                if !service.ports.isEmpty { tags.append("networking") }
                addNode(GraphNode(
                    id: serviceId, type: .service, name: service.name, filePath: file.path,
                    lineRange: service.lineRange,
                    summary: GraphNode.pendingSummary, tags: tags, complexity: .simple
                ))
                addEdge(GraphEdge(source: id, target: serviceId, type: .contains))
            }

            for endpoint in entry.analysis.endpoints {
                let name = [endpoint.method, endpoint.path].compactMap { $0 }.joined(separator: " ")
                let endpointId = "endpoint:\(file.path):\(name)"
                addNode(GraphNode(
                    id: endpointId, type: .endpoint, name: name, filePath: file.path,
                    lineRange: endpoint.lineRange, summary: GraphNode.pendingSummary,
                    tags: ["api-schema", "endpoint"], complexity: .simple
                ))
                addEdge(GraphEdge(source: id, target: endpointId, type: .contains))
            }

            for step in entry.analysis.steps {
                let stepId = "step:\(file.path):\(step.name)"
                addNode(GraphNode(
                    id: stepId, type: .step, name: step.name, filePath: file.path,
                    lineRange: step.lineRange, summary: GraphNode.pendingSummary,
                    tags: ["ci-cd", "build-system"], complexity: .simple
                ))
                addEdge(GraphEdge(source: id, target: stepId, type: .contains))
            }

            for resource in entry.analysis.resources {
                let resourceId = "resource:\(file.path):\(resource.name)"
                addNode(GraphNode(
                    id: resourceId, type: .resource, name: resource.name, filePath: file.path,
                    lineRange: resource.lineRange, summary: GraphNode.pendingSummary,
                    tags: ["infrastructure", resource.kind.lowercased()], complexity: .simple
                ))
                addEdge(GraphEdge(source: id, target: resourceId, type: .contains))
            }

            // Schema definitions become their own nodes; env variables and
            // markdown sections stay context-only, matching upstream.
            for definition in entry.analysis.definitions {
                switch definition.kind {
                case "table", "view":
                    let tableId = "table:\(file.path):\(definition.name)"
                    addNode(GraphNode(
                        id: tableId, type: .table, name: definition.name, filePath: file.path,
                        lineRange: definition.lineRange, summary: GraphNode.pendingSummary,
                        tags: ["database", definition.kind], complexity: .simple
                    ))
                    addEdge(GraphEdge(source: id, target: tableId, type: .contains))
                case "message", "enum", "type", "input", "interface", "union", "scalar":
                    let schemaId = "schema:\(file.path):\(definition.name)"
                    addNode(GraphNode(
                        id: schemaId, type: .schema, name: definition.name, filePath: file.path,
                        lineRange: definition.lineRange, summary: GraphNode.pendingSummary,
                        tags: ["schema-definition", definition.kind], complexity: .simple
                    ))
                    addEdge(GraphEdge(source: id, target: schemaId, type: .contains))
                default:
                    break
                }
            }
        }

        // ── Pass 2: cross-file edges ──
        for entry in analyzed {
            guard let sourceId = fileNodeIds[entry.file.path] else { continue }
            let sourceType = nodeTypesByPath[entry.file.path] ?? .file
            let edgeType = Self.referenceEdgeType(from: sourceType)

            for target in entry.resolvedImports {
                guard let targetId = fileNodeIds[target] else { continue }
                addEdge(GraphEdge(source: sourceId, target: targetId, type: edgeType))
            }
        }

        // ── Pass 3: call edges ──
        //
        // Call-graph entries carry unqualified callee names. A name is resolved
        // against the files this one actually imports first; only if that finds
        // nothing is a globally unique definition accepted. Without the
        // import-first rule, a common name like `render` would wire every file
        // that calls it to every file that defines it.
        for entry in analyzed {
            let importedPaths = Set(entry.resolvedImports)
            for call in entry.analysis.callGraph {
                let callerId = "function:\(entry.file.path):\(call.caller)"
                guard nodeIds.contains(callerId) else { continue }
                guard let candidates = definitionsByName[call.callee], !candidates.isEmpty else {
                    continue
                }

                let imported = candidates.filter { candidateId in
                    guard let path = Self.filePath(ofNodeId: candidateId) else { return false }
                    return importedPaths.contains(path) || path == entry.file.path
                }
                let chosen: [String]
                if !imported.isEmpty {
                    chosen = imported
                } else if candidates.count == 1 {
                    chosen = candidates
                } else {
                    // Ambiguous and not imported — recording it would be a
                    // guess, so it is dropped rather than inventing structure.
                    continue
                }

                for targetId in chosen where targetId != callerId {
                    addEdge(GraphEdge(source: callerId, target: targetId, type: .calls))
                }
            }
        }

        // ── Pass 4: test coverage ──
        let linked = TestLinker.link(nodes: &nodes, edges: &edges, edgeKeys: &edgeKeys)
        if linked > 0 {
            await diagnostics.add(
                .autoCorrected, .alias,
                "Linked \(linked) production file\(linked == 1 ? "" : "s") to their tests by path convention."
            )
        }

        // ── Pass 5: hard caps ──
        //
        // `ScanLimits` documented a node and edge ceiling that nothing ever
        // enforced, which made it a promise rather than a bound. A monorepo can
        // genuinely exceed it, and past that point the renderer's LOD ladder
        // stops being able to hide the cost — so the honest behaviour is to cap
        // and say so, not to quietly try and become unusable.
        //
        // Files are kept over sub-file symbols: a graph of every file and no
        // functions is still a map, where the reverse is not.
        if nodes.count > ScanLimits.maxGraphNodes {
            let dropped = nodes.count - ScanLimits.maxGraphNodes
            nodes.sort { a, b in
                let aFile = NodeType.fileLevel.contains(a.type)
                let bFile = NodeType.fileLevel.contains(b.type)
                if aFile != bFile { return aFile }
                return compareUTF16(a.id, b.id) == .orderedAscending
            }
            nodes.removeLast(dropped)
            let kept = Set(nodes.map(\.id))
            edges.removeAll { !kept.contains($0.source) || !kept.contains($0.target) }
            await diagnostics.add(
                .dropped, .truncated,
                "This project has more than \(ScanLimits.maxGraphNodes) nodes. "
                + "\(dropped) sub-file node\(dropped == 1 ? "" : "s") were left out; "
                + "every file is still present."
            )
        }
        if edges.count > ScanLimits.maxGraphEdges {
            let dropped = edges.count - ScanLimits.maxGraphEdges
            edges.sort { compareUTF16($0.type.rawValue, $1.type.rawValue) == .orderedAscending }
            edges.sort { $0.weight > $1.weight }
            edges.removeLast(dropped)
            await diagnostics.add(
                .dropped, .truncated,
                "More than \(ScanLimits.maxGraphEdges) edges. \(dropped) of the weakest "
                + "were left out."
            )
        }

        return (nodes, edges)
    }

    /// `User.save` → `save`. Free functions come back unchanged.
    static func shortName(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// `User.save` → `User`, or nil for a free function.
    static func ownerTypeName(of name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        return String(name[name.startIndex..<dot])
    }

    /// The file path encoded in a node id, for ids of the form
    /// `<prefix>:<path>[:<name>]`.
    static func filePath(ofNodeId id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    /// Complexity from size, using upstream's thresholds: under 50 non-empty
    /// lines is simple, 50–200 moderate, above that complex.
    static func complexity(ofLines lines: Int, analysis: StructuralAnalysis?) -> Complexity {
        var score = lines
        if let analysis {
            // A file that is short but declares a lot is not simple.
            let declarations = analysis.functions.count + analysis.classes.count
                + analysis.definitions.count + analysis.resources.count
            score = max(score, declarations * 12)
        }
        switch score {
        case ..<50: return .simple
        case ..<201: return .moderate
        default: return .complex
        }
    }
}
