import Foundation

/// Sugiyama layered layout — the Blueprint view's geometry.
///
/// Replaces ELK's `layered` algorithm rather than binding to it, which keeps
/// the binary dependency-free. The four classical phases are all here:
///
///   1. break cycles, so the graph can be ranked at all
///   2. assign ranks by longest path
///   3. reduce edge crossings with the median heuristic
///   4. assign coordinates, packing within each rank
///
/// Upstream's spacing constants are preserved so a graph occupies the same
/// visual scale in both tools.
enum LayeredLayout {
    struct Result: Sendable {
        var positions: [SIMD2<Float>]
        /// Rank each node landed in, used by the morph to stagger by depth.
        var ranks: [Int32]
    }

    /// Crossing-minimisation sweeps. Four is where the curve flattens: more
    /// passes keep improving the count by fractions of a percent while costing
    /// linear time each.
    private static let sweeps = 4

    static func compute(
        _ arrays: GraphArrays,
        subset: [Int32]? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Result {
        let n = arrays.count
        var positions = [SIMD2<Float>](repeating: .zero, count: n)
        var ranks = [Int32](repeating: -1, count: n)
        guard n > 0 else { return Result(positions: positions, ranks: ranks) }

        // Which nodes participate. Everything else keeps a zero position and is
        // simply not drawn.
        let members: [Int32] = subset ?? (0..<Int32(n)).map { $0 }
        guard !members.isEmpty else { return Result(positions: positions, ranks: ranks) }
        var isMember = [Bool](repeating: false, count: n)
        for m in members { isMember[Int(m)] = true }

        // ── Directed edges among members, hierarchy-forming types only ──
        //
        // `imports`, `contains` and `calls` describe direction of dependency;
        // `related` and `similar_to` do not, and including them turns the
        // ranking into mush.
        var outgoing = [[Int32]](repeating: [], count: n)
        var indegree = [Int32](repeating: 0, count: n)
        for e in 0..<arrays.edgeCount {
            let source = arrays.edgeSource[e]
            let target = arrays.edgeTarget[e]
            guard isMember[Int(source)], isMember[Int(target)] else { continue }
            guard Self.isHierarchical(arrays.edgeType[e]) else { continue }
            outgoing[Int(source)].append(target)
            indegree[Int(target)] += 1
        }

        if isCancelled() { return Result(positions: positions, ranks: ranks) }

        // ── Phase 1 + 2: rank by longest path over a cycle-broken order ──
        //
        // Kahn's algorithm consumes the acyclic part; whatever remains is in a
        // cycle and is released in a deterministic order. Import cycles are
        // common enough in real code that refusing to lay out a cyclic graph
        // would mean refusing to lay out most graphs.
        var rank = [Int32](repeating: 0, count: n)
        var remaining = indegree
        var queue = members.filter { remaining[Int($0)] == 0 }.sorted()
        var processed = Set<Int32>()
        var head = 0

        while processed.count < members.count {
            if head >= queue.count {
                // Cycle: release the unprocessed member with the fewest
                // remaining dependencies, breaking ties by index so the result
                // is reproducible.
                let stuck = members
                    .filter { !processed.contains($0) }
                    .min { (remaining[Int($0)], $0) < (remaining[Int($1)], $1) }
                guard let next = stuck else { break }
                queue.append(next)
                remaining[Int(next)] = 0
            }
            let current = queue[head]
            head += 1
            guard processed.insert(current).inserted else { continue }

            for target in outgoing[Int(current)] {
                rank[Int(target)] = max(rank[Int(target)], rank[Int(current)] + 1)
                remaining[Int(target)] -= 1
                if remaining[Int(target)] <= 0, !processed.contains(target) {
                    queue.append(target)
                }
            }
            if isCancelled() { return Result(positions: positions, ranks: ranks) }
        }

        // ── Group into ranks ──
        var byRank: [Int32: [Int32]] = [:]
        for m in members {
            ranks[Int(m)] = rank[Int(m)]
            byRank[rank[Int(m)], default: []].append(m)
        }
        let rankKeys = byRank.keys.sorted()

        // Incoming adjacency, needed by the median heuristic's downward sweep.
        var incoming = [[Int32]](repeating: [], count: n)
        for source in members {
            for target in outgoing[Int(source)] { incoming[Int(target)].append(source) }
        }

        // ── Phase 3: crossing reduction ──
        //
        // Order each rank by the median position of its neighbours in the
        // adjacent rank, alternating direction. Nodes with no neighbours in
        // that direction hold their place, which is what keeps the sort stable.
        var order = byRank
        var positionInRank = [Int32: Int](minimumCapacity: n)
        func reindex() {
            for key in rankKeys {
                for (slot, node) in (order[key] ?? []).enumerated() { positionInRank[node] = slot }
            }
        }
        reindex()

        for sweep in 0..<sweeps {
            if isCancelled() { break }
            let keys = sweep % 2 == 0 ? rankKeys : rankKeys.reversed()
            for key in keys {
                guard var layer = order[key], layer.count > 1 else { continue }
                let neighboursOf: (Int32) -> [Int32] = sweep % 2 == 0
                    ? { incoming[Int($0)] } : { outgoing[Int($0)] }

                let keyed = layer.enumerated().map { slot, node -> (node: Int32, key: Double) in
                    let slots = neighboursOf(node).compactMap { positionInRank[$0] }.sorted()
                    guard !slots.isEmpty else { return (node, Double(slot)) }
                    let middle = slots.count / 2
                    let median = slots.count % 2 == 1
                        ? Double(slots[middle])
                        : Double(slots[middle - 1] + slots[middle]) / 2
                    return (node, median)
                }
                layer = keyed.enumerated()
                    .sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }
                    .map(\.element.node)
                order[key] = layer
            }
            reindex()
        }

        // ── Phase 4: coordinates ──
        //
        // Ranks run down the page and nodes across it. Real dependency graphs
        // are extremely lopsided — most files import nothing, so rank 0 can
        // hold hundreds of nodes while every later rank holds a handful. Laid
        // out as literal rows that produces a drawing tens of thousands of
        // points wide and barely two thousand tall: technically correct and
        // completely unreadable.
        //
        // So a rank wraps. The column cap is derived from the node count to
        // target a roughly 3:2 drawing, which is close enough to a window's
        // shape that "fit to screen" leaves the graph legible.
        let stepY = Float(GraphLayout.nodeHeight + GraphLayout.nodeSpacing)
        let stepX = Float(GraphLayout.nodeWidth + GraphLayout.nodeSpacing)
        let rankGap = Float(GraphLayout.interLayerSpacing)

        let rankSizes = rankKeys.map { order[$0]?.count ?? 0 }
        let columnCap = Self.chooseColumnCap(
            rankSizes: rankSizes, stepX: stepX, stepY: stepY, rankGap: rankGap
        )
        let totalWidth = Float(min(columnCap, members.count)) * stepX

        var y: Float = 0
        for key in rankKeys {
            guard var layer = order[key], !layer.isEmpty else { continue }

            // Once a rank wraps, adjacency within the row is what a reader
            // actually perceives — so group by layer first and keep the
            // crossing-minimised order within each group. Without this a
            // wrapped rank scatters every layer across every row and the
            // colour-coding stops meaning anything spatially.
            if layer.count > columnCap {
                let slotOf = Dictionary(
                    uniqueKeysWithValues: layer.enumerated().map { ($0.element, $0.offset) }
                )
                layer.sort {
                    let layerA = arrays.layerIndex[Int($0)]
                    let layerB = arrays.layerIndex[Int($1)]
                    if layerA != layerB { return layerA < layerB }
                    return (slotOf[$0] ?? 0) < (slotOf[$1] ?? 0)
                }
            }

            let rows = (layer.count + columnCap - 1) / columnCap

            for row in 0..<rows {
                let start = row * columnCap
                let end = min(start + columnCap, layer.count)
                let slice = layer[start..<end]
                let rowWidth = Float(slice.count) * stepX
                // Each row is centred, so a short final row sits under the
                // middle of the rank rather than hanging off the left edge.
                let startX = (totalWidth - rowWidth) / 2
                for (slot, node) in slice.enumerated() {
                    positions[Int(node)] = SIMD2(
                        startX + Float(slot) * stepX + stepX / 2,
                        y + Float(row) * stepY
                    )
                }
            }
            // Extra breathing room between ranks, so a wrapped rank still reads
            // as one band rather than merging into the next.
            y += Float(rows) * stepY + rankGap
        }

        refineRowOrder(&positions, arrays: arrays)
        return Result(positions: positions, ranks: ranks)
    }

    /// Reorders each row by where its neighbours actually ended up.
    ///
    /// The median heuristic above orders a rank by neighbour *slot index*,
    /// which is only proportional to x while the rank fits on one row. Once a
    /// rank wraps, slot 15 with a cap of 10 sits at column 5 of the second row —
    /// so the ordering that minimised crossings is optimising against
    /// coordinates that no longer exist. Two barycentre passes over the real x
    /// values recover most of it.
    ///
    /// Rows and layer grouping are both preserved: nodes only ever swap with
    /// others already on the same row and in the same layer, so the drawing
    /// keeps the structure that makes it readable and only loses the crossings.
    private static func refineRowOrder(
        _ positions: inout [SIMD2<Float>], arrays: GraphArrays
    ) {
        guard positions.count > 2 else { return }

        // Rows are identified by y. Layout assigns them from a small set of
        // exact values, so equality is safe here — these are not accumulated
        // sums, they are `y + row * stepY`.
        var rows: [Float: [Int]] = [:]
        for index in positions.indices { rows[positions[index].y, default: []].append(index) }

        for _ in 0..<2 {
            for (_, members) in rows where members.count > 1 {
                let slots = members.map { positions[$0].x }.sorted()

                // Barycentre: the mean x of everything this node touches. A node
                // with no neighbours keeps its place rather than being dragged
                // to the origin.
                var ordered = members.map { index -> (node: Int, key: Float, layer: Int32) in
                    let neighbours = arrays.neighbours(of: index)
                    guard !neighbours.isEmpty else {
                        return (index, positions[index].x, arrays.layerIndex[index])
                    }
                    var sum: Float = 0
                    for neighbour in neighbours { sum += positions[Int(neighbour)].x }
                    return (index, sum / Float(neighbours.count), arrays.layerIndex[index])
                }

                ordered.sort {
                    if $0.layer != $1.layer { return $0.layer < $1.layer }
                    if $0.key != $1.key { return $0.key < $1.key }
                    // Deterministic tie-break, so the same graph always draws
                    // the same picture.
                    return $0.node < $1.node
                }

                for (slot, entry) in ordered.enumerated() {
                    positions[entry.node].x = slots[slot]
                }
            }
        }
    }

    /// Picks how many nodes a rank may hold before wrapping.
    ///
    /// Derived from the rank *shape* rather than the node count, because the
    /// two say different things: a thousand nodes in three ranks needs a very
    /// different cap from a thousand nodes in three hundred. The cap that gets
    /// closest to a screen-shaped drawing wins.
    ///
    /// A genuinely deep dependency chain still comes out tall, and that is
    /// correct — height in a layered drawing *means* depth, and flattening it
    /// would be a lie about the architecture.
    private static func chooseColumnCap(
        rankSizes: [Int], stepX: Float, stepY: Float, rankGap: Float
    ) -> Int {
        guard let widest = rankSizes.max(), widest > 0 else { return 4 }
        // Slightly wider than tall reads best in a window.
        let targetAspect: Float = 1.4
        let rankCount = Float(rankSizes.count)

        var bestCap = max(4, widest)
        var bestError = Float.greatestFiniteMagnitude

        // A handful of candidates spread across the range is enough; the
        // objective is smooth and an exact optimum is not worth the scan.
        var candidates = Set<Int>([4, widest])
        var candidate = 4
        while candidate < widest {
            candidates.insert(candidate)
            candidate = max(candidate + 1, Int(Float(candidate) * 1.25))
        }

        for cap in candidates.sorted() {
            let rows = rankSizes.reduce(0) { $0 + (($1 + cap - 1) / cap) }
            let width = Float(min(cap, widest)) * stepX
            let height = Float(rows) * stepY + rankCount * rankGap
            guard height > 0, width > 0 else { continue }
            // Compared in log space, so being twice too wide is penalised the
            // same as being twice too tall.
            let error = abs(log(width / height) - log(targetAspect))
            if error < bestError {
                bestError = error
                bestCap = cap
            }
        }
        return max(4, bestCap)
    }

    /// Edge types that imply direction of dependency, and so should influence
    /// ranking. Semantic and coverage edges are relationships without a natural
    /// "above"/"below" and would only add crossings.
    private static func isHierarchical(_ rawType: UInt8) -> Bool {
        guard Int(rawType) < EdgeType.allCases.count else { return false }
        switch EdgeType.allCases[Int(rawType)] {
        case .imports, .contains, .calls, .depends_on, .inherits, .implements,
             .exports, .configures, .deploys, .triggers, .provisions, .serves,
             .routes, .defines_schema, .migrates, .documents, .contains_flow, .flow_step:
            return true
        default:
            return false
        }
    }
}
