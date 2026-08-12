import Foundation

// The knowledge-graph model, kept byte-compatible with Understand Anything's
// `.ua/knowledge-graph.json`. Graphs written here open in the upstream Vite
// dashboard and vice versa, so field names and enum spellings are load-bearing —
// they are the wire format, not an internal detail.
//
// This file is the STRICT model: it is what the app holds in memory and what it
// writes. Reading foreign JSON goes through `GraphSchema`, which parses
// permissively with JSONSerialization and repairs before producing these types.
// Decoding hostile input directly into `Codable` would throw on the first
// unknown enum case and lose the entire graph over one bad node.

// MARK: - Node types

/// 27 node types: 5 code + 8 non-code + 3 domain + 5 knowledge + 6 design.
enum NodeType: String, Codable, CaseIterable, Sendable {
    // Code
    case file, function, `class`, module, concept
    // Non-code
    case config, document, service, table, endpoint, pipeline, schema, resource
    // Business domain
    case domain, flow, step
    // Knowledge base
    case article, entity, topic, claim, source
    // Design (Figma)
    case page, screen, component, componentSet, instance, token

    /// The id prefix this type uses. Node ids are `<prefix>:<path>[:<name>]`.
    var idPrefix: String { rawValue }

    /// Node types that represent a whole file. Layer assignment and the file
    /// explorer only consider these; `function`/`class` are sub-file nodes.
    static let fileLevel: Set<NodeType> = [
        .file, .config, .document, .service, .pipeline, .table, .schema, .resource, .endpoint,
    ]

    /// Broad grouping used by the node-type filter chips.
    var category: NodeCategory {
        switch self {
        case .file, .function, .class, .module, .concept: return .code
        case .config: return .config
        case .document: return .docs
        case .service, .pipeline, .resource: return .infra
        case .table, .schema, .endpoint: return .data
        case .domain, .flow, .step: return .domain
        case .article, .entity, .topic, .claim, .source: return .knowledge
        case .page, .screen, .component, .componentSet, .instance, .token: return .design
        }
    }
}

enum NodeCategory: String, Codable, CaseIterable, Sendable {
    case code, config, docs, infra, data, domain, knowledge, design
}

// MARK: - Edge types

/// 38 edge types across 9 categories.
enum EdgeType: String, Codable, CaseIterable, Sendable {
    // Structural
    case imports, exports, contains, inherits, implements
    // Behavioral
    case calls, subscribes, publishes, middleware
    // Data flow
    case reads_from, writes_to, transforms, validates
    // Dependencies
    case depends_on, tested_by, configures
    // Semantic
    case related, similar_to
    // Infrastructure
    case deploys, serves, provisions, triggers
    // Schema / data
    case migrates, documents, routes, defines_schema
    // Business domain
    case contains_flow, flow_step, cross_domain
    // Knowledge base
    case cites, contradicts, builds_on, exemplifies, categorized_under, authored_by
    // Design
    case instance_of, variant_of, uses_token

    var category: EdgeCategory {
        switch self {
        case .imports, .exports, .contains, .inherits, .implements: return .structural
        case .calls, .subscribes, .publishes, .middleware: return .behavioral
        case .reads_from, .writes_to, .transforms, .validates: return .dataFlow
        case .depends_on, .tested_by, .configures: return .dependencies
        case .related, .similar_to: return .semantic
        case .deploys, .serves, .provisions, .triggers,
             .migrates, .documents, .routes, .defines_schema: return .infrastructure
        case .contains_flow, .flow_step, .cross_domain: return .domain
        case .cites, .contradicts, .builds_on, .exemplifies,
             .categorized_under, .authored_by: return .knowledge
        case .instance_of, .variant_of, .uses_token: return .design
        }
    }

    /// Canonical weight for this edge type, matching upstream's table. The
    /// analyzer prompt asks the model to emit these; deterministic edges use
    /// them directly.
    var canonicalWeight: Double {
        switch self {
        case .contains: return 1.0
        case .inherits, .implements: return 0.9
        case .calls, .exports, .defines_schema: return 0.8
        case .imports, .deploys, .migrates: return 0.7
        case .depends_on, .configures, .triggers: return 0.6
        default: return 0.5
        }
    }
}

enum EdgeCategory: String, Codable, CaseIterable, Sendable {
    case structural, behavioral
    case dataFlow = "data-flow"
    case dependencies, semantic, infrastructure, domain, knowledge, design
}

// MARK: - Scalars

enum Complexity: String, Codable, CaseIterable, Sendable {
    case simple, moderate, complex
}

enum EdgeDirection: String, Codable, CaseIterable, Sendable {
    case forward, backward, bidirectional
}

/// Inclusive 1-based line span. Serialized as a two-element JSON array
/// (`[start, end]`) to match the upstream schema.
struct LineRange: Codable, Hashable, Sendable {
    var start: Int
    var end: Int

    init(_ start: Int, _ end: Int) {
        self.start = start
        self.end = end
    }

    /// Line count, clamped at zero so a malformed range can never produce a
    /// negative that then propagates into size heuristics.
    var lineCount: Int { max(0, end - start + 1) }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        start = try c.decode(Int.self)
        end = try c.decode(Int.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(start)
        try c.encode(end)
    }
}

// MARK: - Optional per-type metadata

struct KnowledgeMeta: Codable, Hashable, Sendable {
    var wikilinks: [String]?
    var backlinks: [String]?
    var category: String?
    var content: String?
}

struct DomainMeta: Codable, Hashable, Sendable {
    enum EntryType: String, Codable, Sendable {
        case http, cli, event, cron, manual
    }

    var entities: [String]?
    var businessRules: [String]?
    var crossDomainInteractions: [String]?
    var entryPoint: String?
    var entryType: EntryType?
}

struct FigmaMeta: Codable, Hashable, Sendable {
    struct Dimensions: Codable, Hashable, Sendable {
        var width: Double
        var height: Double
    }

    enum TokenKind: String, Codable, Sendable {
        case color, type, spacing, effect, grid
    }

    var fileKey: String?
    /// Figma node id, e.g. `"1:23"`.
    var nodeId: String?
    /// FRAME | COMPONENT | COMPONENT_SET | INSTANCE | TEXT …
    var figmaType: String?
    var thumbnailUrl: String?
    var dimensions: Dimensions?
    var tokenKind: TokenKind?
    /// e.g. `"#0A84FF"`, `"16px"`.
    var tokenValue: String?
    var prototypeTargets: [String]?
    var componentKey: String?
}

// MARK: - Graph

struct GraphNode: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var type: NodeType
    var name: String
    var filePath: String?
    var lineRange: LineRange?
    var summary: String
    var tags: [String]
    var complexity: Complexity
    var languageNotes: String?
    var domainMeta: DomainMeta?
    var knowledgeMeta: KnowledgeMeta?
    var figmaMeta: FigmaMeta?

    init(
        id: String,
        type: NodeType,
        name: String,
        filePath: String? = nil,
        lineRange: LineRange? = nil,
        summary: String,
        tags: [String],
        complexity: Complexity = .moderate,
        languageNotes: String? = nil,
        domainMeta: DomainMeta? = nil,
        knowledgeMeta: KnowledgeMeta? = nil,
        figmaMeta: FigmaMeta? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.filePath = filePath
        self.lineRange = lineRange
        self.summary = summary
        self.tags = tags
        self.complexity = complexity
        self.languageNotes = languageNotes
        self.domainMeta = domainMeta
        self.knowledgeMeta = knowledgeMeta
        self.figmaMeta = figmaMeta
    }

    /// True when this node carries a real summary rather than the placeholder
    /// the deterministic pipeline emits before enrichment runs.
    var isEnriched: Bool { !summary.isEmpty && summary != GraphNode.pendingSummary }

    /// Placeholder used by the deterministic pipeline. The schema requires a
    /// non-empty summary, and an honest "not yet analyzed" marker beats
    /// inventing prose the app cannot actually derive.
    static let pendingSummary = "Not yet analyzed."
}

struct GraphEdge: Codable, Hashable, Sendable {
    var source: String
    var target: String
    var type: EdgeType
    var direction: EdgeDirection
    var description: String?
    /// 0...1.
    var weight: Double

    init(
        source: String,
        target: String,
        type: EdgeType,
        direction: EdgeDirection = .forward,
        description: String? = nil,
        weight: Double? = nil
    ) {
        self.source = source
        self.target = target
        self.type = type
        self.direction = direction
        self.description = description
        self.weight = weight ?? type.canonicalWeight
    }

    /// Upstream's Python merge dedups on (source, target, type, direction);
    /// its TypeScript normalizer dedups on (source, target, type). We use the
    /// narrower key so both passes agree — two edges differing only by
    /// direction are a direction bug, not two distinct relationships.
    var dedupeKey: String { "\(source)\u{1}\(target)\u{1}\(type.rawValue)" }
}

struct Layer: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var nodeIds: [String]
}

struct TourStep: Codable, Hashable, Sendable {
    var order: Int
    var title: String
    var description: String
    var nodeIds: [String]
    var languageLesson: String?
}

struct ProjectMeta: Codable, Hashable, Sendable {
    var name: String
    var languages: [String]
    var frameworks: [String]
    var description: String
    /// ISO 8601.
    var analyzedAt: String
    var gitCommitHash: String
}

/// What kind of thing the graph describes. Absent means `codebase`; the schema
/// normalizer keys some type aliases off this, so it round-trips.
enum GraphKind: String, Codable, Sendable {
    case codebase, knowledge, design
}

struct KnowledgeGraph: Codable, Sendable {
    var version: String
    var kind: GraphKind?
    var project: ProjectMeta
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var layers: [Layer]
    var tour: [TourStep]

    static let currentVersion = "1.0.0"

    init(
        version: String = KnowledgeGraph.currentVersion,
        kind: GraphKind? = nil,
        project: ProjectMeta,
        nodes: [GraphNode] = [],
        edges: [GraphEdge] = [],
        layers: [Layer] = [],
        tour: [TourStep] = []
    ) {
        self.version = version
        self.kind = kind
        self.project = project
        self.nodes = nodes
        self.edges = edges
        self.layers = layers
        self.tour = tour
    }
}

// MARK: - Sidecar files

/// `.ua/meta.json` — analysis bookkeeping, separate from the graph so it can be
/// rewritten without touching (or risking) the graph itself.
struct AnalysisMeta: Codable, Sendable {
    var lastAnalyzedAt: String
    var gitCommitHash: String
    var version: String
    var analyzedFiles: Int
    var theme: ThemeConfig?
}

struct ThemeConfig: Codable, Hashable, Sendable {
    var presetId: String
    var accentId: String
    var headingFont: String?
}

/// `.ua/config.json` — per-project preferences shared with the upstream plugin.
struct ProjectConfig: Codable, Sendable {
    var autoUpdate: Bool
    var outputLanguage: String?

    init(autoUpdate: Bool = false, outputLanguage: String? = nil) {
        self.autoUpdate = autoUpdate
        self.outputLanguage = outputLanguage
    }

    /// The project's stored output language, shared with the upstream plugin's
    /// `.ua/config.json` so a language chosen in either tool applies in both.
    static func outputLanguage(projectRoot: String) -> String? {
        JSONFile.read(ProjectConfig.self, from: DataDirectory.configPath(projectRoot))?
            .outputLanguage
    }
}

// MARK: - Scan model

/// How a file is treated by the pipeline. Drives which extractor runs and which
/// node type the file becomes.
enum FileCategory: String, Codable, CaseIterable, Sendable {
    case code, config, docs, infra, data, script, markup

    /// Call-graph extraction is only meaningful for executable files.
    var wantsCallGraph: Bool { self == .code || self == .script }
}

/// One file as discovered by the scanner.
struct ScannedFile: Codable, Hashable, Sendable {
    /// Project-relative POSIX path.
    var path: String
    /// Language id from `LanguageRegistry`, never nil (falls back to the raw
    /// extension, then `"unknown"`).
    var language: String
    /// `wc -l` semantics: the number of 0x0A bytes in the file.
    var sizeLines: Int
    var fileCategory: FileCategory

    var basename: String {
        path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
    }
}

enum ProjectComplexity: String, Codable, Sendable {
    case small, moderate, large
    case veryLarge = "very-large"

    init(fileCount: Int) {
        switch fileCount {
        case ..<31: self = .small
        case ..<151: self = .moderate
        case ..<501: self = .large
        default: self = .veryLarge
        }
    }
}

/// Output of the scan phase — the deterministic file inventory everything else
/// is derived from.
struct ScanResult: Codable, Sendable {
    var projectName: String
    var projectDescription: String
    var files: [ScannedFile]
    var languages: [String]
    var frameworks: [String]
    var totalFiles: Int
    var filteredByIgnore: Int
    var estimatedComplexity: ProjectComplexity
    /// SHA-256 over every scanned file's path and bytes, in sorted path order.
    /// Two scans with the same digest describe identical trees, which is what
    /// makes the layout cache safe to reuse.
    var contentDigest: String
    var entryPoint: String?
}

// MARK: - Structural analysis (extractor output)

struct FunctionInfo: Codable, Hashable, Sendable {
    var name: String
    var lineRange: LineRange
    var params: [String]
    var returnType: String?
}

struct ClassInfo: Codable, Hashable, Sendable {
    var name: String
    var lineRange: LineRange
    var methods: [String]
    var properties: [String]
}

struct ImportInfo: Codable, Hashable, Sendable {
    /// The raw import specifier as written in the source, unmodified. Python's
    /// resolver counts leading dots, so preserving it verbatim matters.
    var source: String
    var specifiers: [String]
    var lineNumber: Int
}

struct ExportInfo: Codable, Hashable, Sendable {
    var name: String
    var lineNumber: Int
    var isDefault: Bool
}

struct SectionInfo: Codable, Hashable, Sendable {
    var name: String
    var level: Int
    var lineRange: LineRange
}

struct DefinitionInfo: Codable, Hashable, Sendable {
    var name: String
    /// Parser-reported kind: table, view, index, message, enum, type, input,
    /// interface, union, scalar, variable, output, resource, data, section,
    /// target, stage.
    var kind: String
    var lineRange: LineRange
    var fields: [String]
}

struct ServiceInfo: Codable, Hashable, Sendable {
    var name: String
    var image: String?
    var ports: [Int]
    var lineRange: LineRange?
}

struct EndpointInfo: Codable, Hashable, Sendable {
    var method: String?
    var path: String
    var lineRange: LineRange
}

struct StepInfo: Codable, Hashable, Sendable {
    var name: String
    var lineRange: LineRange
}

struct ResourceInfo: Codable, Hashable, Sendable {
    var name: String
    var kind: String
    var lineRange: LineRange
}

struct CallGraphEntry: Codable, Hashable, Sendable {
    var caller: String
    var callee: String
    var lineNumber: Int
}

/// Everything an extractor can find in one file. Code extractors fill the first
/// four arrays; non-code parsers fill the rest. All are empty by default so a
/// parser only populates what it actually understands.
struct StructuralAnalysis: Codable, Hashable, Sendable {
    var functions: [FunctionInfo] = []
    var classes: [ClassInfo] = []
    var imports: [ImportInfo] = []
    var exports: [ExportInfo] = []
    var sections: [SectionInfo] = []
    var definitions: [DefinitionInfo] = []
    var services: [ServiceInfo] = []
    var endpoints: [EndpointInfo] = []
    var steps: [StepInfo] = []
    var resources: [ResourceInfo] = []
    var callGraph: [CallGraphEntry] = []

    var isEmpty: Bool {
        functions.isEmpty && classes.isEmpty && imports.isEmpty && exports.isEmpty
            && sections.isEmpty && definitions.isEmpty && services.isEmpty
            && endpoints.isEmpty && steps.isEmpty && resources.isEmpty
    }

    /// Names of everything this file exports, for fast membership tests during
    /// cross-file edge resolution.
    var exportedNames: Set<String> { Set(exports.map(\.name)) }
}
