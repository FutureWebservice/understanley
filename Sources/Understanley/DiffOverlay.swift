import Foundation

/// What your uncommitted changes touch, and what they ripple into.
///
/// The question a diff view answers is not "which files did I edit" — git
/// already says that — but "what else might this break". That is the graph's
/// job: walk out from the changed files along the edges that represent real
/// dependency, and mark what depends on them.
struct DiffOverlay: Sendable {
    /// Nodes whose own file changed.
    var changed: Set<Int32> = []
    /// Nodes reachable from a changed node by dependency, within `depth` hops.
    var affected: Set<Int32> = []
    /// Project-relative paths git reported, including ones with no node.
    var changedFiles: [String] = []
    /// How far the ripple was traced.
    var depth: Int = 2

    var isEmpty: Bool { changed.isEmpty && affected.isEmpty }
    var totalTouched: Int { changed.count + affected.count }

    static let empty = DiffOverlay()

    /// Builds the overlay for a set of changed paths.
    ///
    /// The walk runs *backwards* along dependency edges: if `a` imports `b` and
    /// `b` changed, then `a` is affected. Walking forwards would mark a changed
    /// file's own dependencies, which are exactly the things that did not move.
    static func compute(
        changedFiles: [String], arrays: GraphArrays, graph: KnowledgeGraph, depth: Int = 2
    ) -> DiffOverlay {
        guard !changedFiles.isEmpty, !arrays.isEmpty else { return .empty }
        let changedSet = Set(changedFiles.map(PosixPath.normalize))

        // Every node belonging to a changed file, at any level — a changed file
        // means its functions and classes changed too.
        var changed = Set<Int32>()
        for (index, node) in graph.nodes.enumerated() {
            guard let path = node.filePath, changedSet.contains(PosixPath.normalize(path)) else {
                continue
            }
            changed.insert(Int32(index))
        }
        guard !changed.isEmpty else {
            return DiffOverlay(changed: [], affected: [], changedFiles: changedFiles, depth: depth)
        }

        // Reverse adjacency over dependency-bearing edges only. `related` and
        // `similar_to` say two things resemble each other, not that one breaks
        // when the other moves — including them would mark half the graph.
        var dependents = [Int32: [Int32]](minimumCapacity: arrays.count)
        for e in 0..<arrays.edgeCount {
            guard Int(arrays.edgeType[e]) < EdgeType.allCases.count else { continue }
            let type = EdgeType.allCases[Int(arrays.edgeType[e])]
            guard type.propagatesChange else { continue }
            // source depends on target, so a change in target reaches source.
            dependents[arrays.edgeTarget[e], default: []].append(arrays.edgeSource[e])
        }

        var affected = Set<Int32>()
        var frontier = changed
        for _ in 0..<max(0, depth) {
            var next = Set<Int32>()
            for node in frontier {
                for dependent in dependents[node] ?? [] {
                    guard !changed.contains(dependent), !affected.contains(dependent) else {
                        continue
                    }
                    affected.insert(dependent)
                    next.insert(dependent)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }

        return DiffOverlay(
            changed: changed, affected: affected, changedFiles: changedFiles, depth: depth
        )
    }
}

extension EdgeType {
    /// Whether a change at the target plausibly reaches the source.
    ///
    /// Structural and behavioural dependencies do; semantic resemblance does
    /// not. `tested_by` is deliberately included in the other direction only —
    /// a production change matters to its test, which is what the edge already
    /// encodes.
    var propagatesChange: Bool {
        switch self {
        case .imports, .calls, .depends_on, .inherits, .implements, .exports,
             .contains, .configures, .defines_schema, .middleware,
             .reads_from, .writes_to, .transforms, .validates,
             .subscribes, .publishes, .routes, .serves, .tested_by:
            return true
        case .related, .similar_to, .documents, .deploys, .provisions, .triggers,
             .migrates, .contains_flow, .flow_step, .cross_domain,
             .cites, .contradicts, .builds_on, .exemplifies, .categorized_under,
             .authored_by, .instance_of, .variant_of, .uses_token:
            return false
        }
    }
}

// MARK: - Freshness presentation

extension GitProbe.Freshness {
    /// How much attention this state deserves. Drives whether a banner shows at
    /// all and in what colour.
    var severity: Int {
        switch self {
        case .fresh: return 0
        case .unknown: return 1
        case .dirty: return 2
        case .stale: return 3
        }
    }

    var headline: String {
        switch self {
        case .fresh:
            return "Up to date"
        case .dirty(let files):
            return "\(files.count) uncommitted change\(files.count == 1 ? "" : "s")"
        case .stale(let relation, let behind, _, _):
            switch relation {
            case .behind:
                return "\(behind) commit\(behind == 1 ? "" : "s") behind this graph"
            case .ahead:
                return "This graph is newer than your checkout"
            case .diverged:
                return "Your branch and this graph have diverged"
            }
        case .unknown:
            return "Freshness unknown"
        }
    }

    var detail: String {
        switch self {
        case .fresh:
            return "The graph matches your working tree."
        case .dirty:
            return "The graph reflects your last commit. Re-analyze to include what you have edited since."
        case .stale:
            return "Files have changed since this graph was built. Re-analyze to bring it up to date."
        case .unknown(let reason):
            return reason.explanation
        }
    }

    /// Files that differ from what the graph describes.
    var changedFiles: [String] {
        switch self {
        case .fresh, .unknown: return []
        case .dirty(let files): return files
        case .stale(_, _, _, let files): return files
        }
    }

    var isActionable: Bool { severity >= 2 }
}
