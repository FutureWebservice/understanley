import Foundation

/// One thing the pipeline noticed and handled. Ported from upstream's
/// `GraphIssue`, and it exists for the same reason: the analyzer repairs a lot
/// of imperfect input, and every repair has to stay visible.
///
/// Upstream's rule is *never silently drop errors* — a dropped edge or a
/// coerced field changes what the user sees, so it gets recorded and surfaced,
/// not swallowed.
struct GraphIssue: Codable, Hashable, Sendable {
    enum Level: String, Codable, Sendable, Comparable {
        /// A value was repaired in place; the graph is usable.
        case autoCorrected = "auto-corrected"
        /// An item was removed; the rest of the graph is usable.
        case dropped
        /// The graph could not be loaded at all.
        case fatal

        private var severity: Int {
            switch self {
            case .autoCorrected: return 0
            case .dropped: return 1
            case .fatal: return 2
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.severity < rhs.severity }
    }

    /// Kebab-case bucket, so the diagnostics panel can group without parsing
    /// message text. Matches upstream's category vocabulary.
    enum Category: String, Codable, Sendable {
        case missingField = "missing-field"
        case alias
        case typeCoercion = "type-coercion"
        case outOfRange = "out-of-range"
        case invalidCollection = "invalid-collection"
        case invalidNode = "invalid-node"
        case invalidEdge = "invalid-edge"
        case invalidReference = "invalid-reference"
        case invalidLayer = "invalid-layer"
        case invalidTourStep = "invalid-tour-step"
        case unresolvedImport = "unresolved-import"
        case unresolvedWikilink = "unresolved-wikilink"
        case skippedFile = "skipped-file"
        case truncated
        case parserFailure = "parser-failure"
        case providerFailure = "provider-failure"
    }

    var level: Level
    var category: Category
    var message: String
    /// Where the problem is, e.g. `nodes[3].complexity` or a file path.
    var path: String?

    init(_ level: Level, _ category: Category, _ message: String, path: String? = nil) {
        self.level = level
        self.category = category
        self.message = message
        self.path = path
    }
}

/// Thread-safe collector for issues raised across concurrent analysis tasks.
///
/// An actor rather than a lock because the producers are already async: the
/// scanner, the extractors and the enrichment batches all run off the main
/// actor and all report into one place.
actor DiagnosticsCollector {
    private var issues: [GraphIssue] = []
    /// Per-category counts, kept even after `cap` stops storing full records so
    /// the summary line stays truthful on a pathological project.
    private var counts: [GraphIssue.Category: Int] = [:]

    /// Stored-record ceiling. A project that raises a million unresolved
    /// imports should still render; the panel shows the first `cap` and an
    /// accurate total.
    private let cap: Int

    init(cap: Int = 10_000) {
        self.cap = cap
    }

    func add(_ issue: GraphIssue) {
        counts[issue.category, default: 0] += 1
        guard issues.count < cap else { return }
        issues.append(issue)
    }

    func add(_ newIssues: [GraphIssue]) {
        for issue in newIssues { add(issue) }
    }

    func add(_ level: GraphIssue.Level, _ category: GraphIssue.Category, _ message: String, path: String? = nil) {
        add(GraphIssue(level, category, message, path: path))
    }

    /// Everything recorded, worst level first, then grouped by category so the
    /// panel reads in priority order without re-sorting.
    func snapshot() -> DiagnosticsReport {
        let sorted = issues.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            return $0.category.rawValue < $1.category.rawValue
        }
        return DiagnosticsReport(issues: sorted, totals: counts, truncated: totalCount > issues.count)
    }

    var totalCount: Int { counts.values.reduce(0, +) }
}

/// An immutable snapshot of collected diagnostics, safe to hand to the UI.
struct DiagnosticsReport: Sendable {
    var issues: [GraphIssue]
    var totals: [GraphIssue.Category: Int]
    /// True when more issues occurred than were stored.
    var truncated: Bool

    var isEmpty: Bool { issues.isEmpty }
    var total: Int { totals.values.reduce(0, +) }

    var fatalCount: Int { issues.filter { $0.level == .fatal }.count }
    var droppedCount: Int { issues.filter { $0.level == .dropped }.count }
    var correctedCount: Int { issues.filter { $0.level == .autoCorrected }.count }

    /// Highest level present, or nil when clean — drives whether the banner
    /// shows at all and in what colour.
    var worstLevel: GraphIssue.Level? { issues.map(\.level).max() }

    static let empty = DiagnosticsReport(issues: [], totals: [:], truncated: false)

    /// Plain-text report for the diagnostics panel's Copy button.
    func plainText() -> String {
        var out = "Understanley — analysis diagnostics\n"
        out += "\(total) issue\(total == 1 ? "" : "s")"
        if truncated { out += " (showing first \(issues.count))" }
        out += "\n\n"
        for issue in issues {
            out += "[\(issue.level.rawValue)] \(issue.category.rawValue): \(issue.message)"
            if let path = issue.path { out += "  (\(path))" }
            out += "\n"
        }
        return out
    }
}
