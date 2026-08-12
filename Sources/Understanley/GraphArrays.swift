import Foundation

/// Per-node render state, packed into one byte.
struct NodeFlags: OptionSet, Sendable {
    let rawValue: UInt8

    static let fileLevel = NodeFlags(rawValue: 1 << 0)
    static let tested = NodeFlags(rawValue: 1 << 1)
    static let entryPoint = NodeFlags(rawValue: 1 << 2)
    static let isTest = NodeFlags(rawValue: 1 << 3)
    static let changed = NodeFlags(rawValue: 1 << 4)
    static let affected = NodeFlags(rawValue: 1 << 5)
    static let enriched = NodeFlags(rawValue: 1 << 6)
}

/// The graph, compiled for drawing.
///
/// The renderer never touches `GraphNode`. Every frame walks contiguous
/// `Float`/`Int32` arrays instead — no reference counting, no dictionary
/// lookups, no optional unwrapping in the hot loop. On a 10 000-node graph at
/// 60 fps that is the difference between smooth and unusable, and it is the
/// single largest performance decision in the app.
///
/// String ids survive only in `indexByID`, used at the boundary where the UI
/// asks about a specific node.
struct GraphArrays: Sendable {
    // MARK: Identity

    var ids: [String] = []
    var names: [String] = []
    var types: [NodeType] = []
    /// One-line description, shown on the card when it is big enough to hold
    /// it. Kept here rather than looked up through `GraphNode` so the draw loop
    /// never touches the model.
    var summaries: [String] = []
    var complexity: [Complexity] = []
    var indexByID: [String: Int32] = [:]

    // MARK: Visual attributes

    /// Hue in degrees, derived from the node's layer and type.
    var hues: [Float] = []
    /// 0…1, from complexity.
    var brightness: [Float] = []
    /// Universe body radius, from connection degree.
    var radii: [Float] = []
    /// Layer ordinal, or -1 when the node belongs to none.
    var layerIndex: [Int32] = []
    var flags: [NodeFlags] = []
    /// Stable per-node phase offset so breathing never pulses in unison.
    var phase: [Float] = []

    // MARK: Geometry

    /// Positions in the layered view. Node origin is its centre.
    var blueprint: [SIMD2<Float>] = []
    /// Positions in the force-directed view.
    var universe: [SIMD2<Float>] = []
    /// Card size in the layered view.
    var cardSize: [SIMD2<Float>] = []

    // MARK: Edges

    var edgeSource: [Int32] = []
    var edgeTarget: [Int32] = []
    var edgeType: [UInt8] = []

    // MARK: Adjacency (CSR)

    /// `adjTargets[adjOffsets[i] ..< adjOffsets[i+1]]` are node `i`'s
    /// neighbours, both directions merged. Compressed sparse row rather than
    /// `[[Int]]`: one allocation instead of N, and neighbour walks stay in
    /// cache — which matters because selection, focus and path finding all do
    /// exactly this walk.
    var adjOffsets: [Int32] = []
    var adjTargets: [Int32] = []
    var degree: [Int32] = []

    // MARK: Layers

    var layerNames: [String] = []
    var layerHues: [Float] = []

    var count: Int { ids.count }
    var edgeCount: Int { edgeSource.count }
    var isEmpty: Bool { ids.isEmpty }

    // MARK: - Compilation

    /// Builds the render form. Positions are left at zero; a layout pass fills
    /// them in.
    static func compile(_ graph: KnowledgeGraph, entryPoint: String? = nil) -> GraphArrays {
        var out = GraphArrays()
        let n = graph.nodes.count
        out.ids.reserveCapacity(n)
        out.names.reserveCapacity(n)
        out.types.reserveCapacity(n)
        out.summaries.reserveCapacity(n)
        out.complexity.reserveCapacity(n)
        out.indexByID.reserveCapacity(n)

        // Layer ordinal per node id, and the layer palette.
        var layerOfNode: [String: Int32] = [:]
        for (ordinal, layer) in graph.layers.enumerated() {
            out.layerNames.append(layer.name)
            out.layerHues.append(Palette.layerHue(ordinal))
            for id in layer.nodeIds where layerOfNode[id] == nil {
                layerOfNode[id] = Int32(ordinal)
            }
        }

        for (index, node) in graph.nodes.enumerated() {
            out.ids.append(node.id)
            out.names.append(node.name)
            out.types.append(node.type)
            out.summaries.append(node.isEnriched ? node.summary : "")
            out.complexity.append(node.complexity)
            out.indexByID[node.id] = Int32(index)

            var nodeFlags = NodeFlags()
            if NodeType.fileLevel.contains(node.type) { nodeFlags.insert(.fileLevel) }
            if node.tags.contains("tested") { nodeFlags.insert(.tested) }
            if node.tags.contains("entry-point") { nodeFlags.insert(.entryPoint) }
            if node.tags.contains("test") { nodeFlags.insert(.isTest) }
            if node.isEnriched { nodeFlags.insert(.enriched) }
            if let entryPoint, node.filePath == entryPoint { nodeFlags.insert(.entryPoint) }
            out.flags.append(nodeFlags)

            // A sub-file node inherits its file's layer, so a function is
            // coloured like the file it lives in rather than falling to grey.
            var layer = layerOfNode[node.id] ?? -1
            if layer < 0, let path = node.filePath {
                for prefix in ["file:", "config:", "document:", "service:", "pipeline:",
                               "schema:", "resource:", "table:", "endpoint:"] {
                    if let owner = layerOfNode[prefix + path] { layer = owner; break }
                }
            }
            out.layerIndex.append(layer)

            let layerHue = layer >= 0 && Int(layer) < out.layerHues.count
                ? out.layerHues[Int(layer)]
                : Palette.layerHue(0)
            out.hues.append(Palette.nodeHue(layerHue: layerHue, type: node.type))
            out.brightness.append(Palette.brightness(for: node.complexity))
            out.phase.append(Float(Hash.stable64(node.id) % 6283) / 1000)

            out.cardSize.append(SIMD2(Float(GraphLayout.nodeWidth), Float(GraphLayout.nodeHeight)))
            out.blueprint.append(.zero)
            out.universe.append(.zero)
            out.radii.append(0)
        }

        // Edges, dropping any that reference a node the graph does not contain.
        // Validation should already guarantee this; the check costs nothing and
        // a dangling index would be an out-of-bounds crash in the draw loop.
        var counts = [Int32](repeating: 0, count: n)
        out.edgeSource.reserveCapacity(graph.edges.count)

        // One line per ordered pair, keeping the strongest relationship.
        //
        // The graph legitimately holds several edges between the same two
        // nodes — every exported top-level function is both `contains` and
        // `exports` from its file, which is 38 of gitrocket's 131 edges. Both
        // belong in the JSON, because that is what upstream writes and
        // interoperability is the point. But drawing both stacks two lines in
        // exactly the same place: it costs a second stroke to render, makes the
        // graph look denser than it is, and double-counts degree, which is what
        // sets each body's radius.
        var strongestByPair: [Int64: Int] = [:]
        strongestByPair.reserveCapacity(graph.edges.count)

        for edge in graph.edges {
            guard let source = out.indexByID[edge.source],
                  let target = out.indexByID[edge.target],
                  source != target else { continue }
            let key = Int64(source) << 32 | Int64(UInt32(bitPattern: target))
            let typeCode = UInt8(EdgeType.allCases.firstIndex(of: edge.type) ?? 0)

            if let existing = strongestByPair[key] {
                let incumbent = EdgeType.allCases[Int(out.edgeType[existing])]
                guard edge.type.canonicalWeight > incumbent.canonicalWeight else { continue }
                out.edgeType[existing] = typeCode
                continue
            }

            strongestByPair[key] = out.edgeSource.count
            out.edgeSource.append(source)
            out.edgeTarget.append(target)
            out.edgeType.append(typeCode)
            counts[Int(source)] += 1
            counts[Int(target)] += 1
        }
        out.degree = counts

        // Build CSR adjacency with a counting sort — two passes, no
        // intermediate arrays-of-arrays.
        var offsets = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { offsets[i + 1] = offsets[i] + counts[i] }
        out.adjOffsets = offsets
        out.adjTargets = [Int32](repeating: 0, count: Int(offsets[n]))
        var cursor = offsets
        for e in 0..<out.edgeSource.count {
            let source = out.edgeSource[e]
            let target = out.edgeTarget[e]
            out.adjTargets[Int(cursor[Int(source)])] = target
            cursor[Int(source)] += 1
            out.adjTargets[Int(cursor[Int(target)])] = source
            cursor[Int(target)] += 1
        }

        // Radius follows degree, so the hubs read as the hubs.
        for i in 0..<n {
            out.radii[i] = Palette.radius(degree: Int(counts[i]))
        }

        return out
    }

    // MARK: - Queries

    /// Every node of one type, in graph order.
    func indices(ofType type: NodeType) -> [Int] {
        (0..<count).filter { types[$0] == type }
    }

    /// Neighbours of `index`, in both directions.
    func neighbours(of index: Int) -> ArraySlice<Int32> {
        guard index >= 0, index + 1 < adjOffsets.count else { return [][...] }
        return adjTargets[Int(adjOffsets[index])..<Int(adjOffsets[index + 1])]
    }

    func index(of id: String) -> Int? {
        indexByID[id].map(Int.init)
    }

    /// One-hop neighbourhood including the node itself. Used by focus mode and
    /// by the renderer's selection dimming.
    func neighbourhood(of index: Int) -> Set<Int32> {
        var out: Set<Int32> = [Int32(index)]
        for neighbour in neighbours(of: index) { out.insert(neighbour) }
        return out
    }

    /// Shortest path between two nodes over the undirected adjacency, or empty
    /// when none exists. Breadth-first over CSR arrays, so it is effectively
    /// instant even on large graphs.
    func shortestPath(from start: Int, to end: Int) -> [Int] {
        guard start != end, start < count, end < count else { return start == end ? [start] : [] }
        var previous = [Int32](repeating: -2, count: count)
        previous[start] = -1
        var queue = [Int32(start)]
        var head = 0

        while head < queue.count {
            let current = Int(queue[head])
            head += 1
            for neighbour in neighbours(of: current) where previous[Int(neighbour)] == -2 {
                previous[Int(neighbour)] = Int32(current)
                if Int(neighbour) == end {
                    var path = [end]
                    var walk = Int32(current)
                    while walk >= 0 {
                        path.append(Int(walk))
                        walk = previous[Int(walk)]
                    }
                    return path.reversed()
                }
                queue.append(neighbour)
            }
        }
        return []
    }

    /// Bounding box over the given positions, with padding.
    ///
    /// Non-finite coordinates are skipped rather than propagated: a single NaN
    /// would make the whole rect NaN, and converting that to an integer traps.
    static func bounds(of positions: [SIMD2<Float>], padding: Float = 120) -> CGRect {
        let finite = positions.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in finite {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(
            x: CGFloat(minX - padding), y: CGFloat(minY - padding),
            width: CGFloat(maxX - minX + padding * 2),
            height: CGFloat(maxY - minY + padding * 2)
        )
    }
}

// MARK: - Spatial index

/// Floors to an `Int`, saturating instead of trapping.
///
/// Two things every grid-bucketing site here needs, and neither is free:
///
/// *Floor, not truncation.* `Int(-1.5)` is `-1` but the cell below zero is
/// `-2`. Layouts are centred on the origin, so half the coordinates are
/// negative and truncation would fold two adjacent cells into one.
///
/// *Saturation, not a trap.* `Int(someFloat)` traps outright on NaN, on
/// infinity, and on any magnitude beyond `Int`. These call sites take layout
/// geometry or the live camera rect, and neither is provably in range — a force
/// simulation can diverge, and a user can zoom until the visible rect
/// overflows. A clamped cell index is a slightly coarser cull; a trap is a
/// crash the user cannot recover from.
@inline(__always)
func floorToInt(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    return Int(min(max(value.rounded(.down), -1e15), 1e15))
}

/// Uniform grid over node positions, for culling and hit-testing.
///
/// The canvas draws thousands of nodes but a viewport shows tens, and
/// hit-testing has to answer "what is under the cursor" on every mouse move.
/// A grid answers both in constant time. It is rebuilt whenever a layout
/// finishes, which is rare compared to how often it is queried.
struct SpatialIndex: Sendable {
    /// Hard ceiling per axis. The grid is allocated eagerly, so extent has to
    /// stop translating into allocation at some point.
    private static let maximumAxisCells = 2048

    private let cellSize: Float
    private let origin: SIMD2<Float>
    private let columns: Int
    private let rows: Int
    /// Flattened buckets, CSR-style.
    private let bucketOffsets: [Int32]
    private let bucketItems: [Int32]

    static let empty = SpatialIndex()

    private init() {
        cellSize = 1
        origin = .zero
        columns = 0
        rows = 0
        bucketOffsets = [0]
        bucketItems = []
    }

    // The parameter is deliberately not called `cellSize`: it would shadow the
    // property, and then `cellSize` inside this initialiser means the requested
    // value while `cellSize` inside a query means the stored one. Those two
    // differ whenever the extent forces a coarser grid, and the index silently
    // stops finding anything.
    init(positions: [SIMD2<Float>], cellSize requestedCell: Float = 400) {
        guard !positions.isEmpty else { self = .empty; return }

        // Only finite positions define the extent. One NaN or one infinity
        // would otherwise set the origin for the whole index, and every query
        // after that returns nothing — a blank canvas with no error anywhere,
        // which is worse than a crash because it looks like an empty project.
        // Unusable positions still get bucketed below; they just clamp to an
        // edge cell instead of dictating where the edges are.
        var minX = Float.infinity, maxX = -Float.infinity
        var minY = Float.infinity, maxY = -Float.infinity
        for p in positions where p.x.isFinite && p.y.isFinite {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        if minX > maxX { minX = 0; maxX = 0; minY = 0; maxY = 0 }

        // The grid is allocated eagerly, so extent must stop translating into
        // allocation somewhere. Grow the *cell* to fit the extent rather than
        // clamping the column count: clamping piles every node past the cap
        // into the final cell, so one distant outlier would push the entire
        // real graph into a corner and a query near it would find nothing.
        // A coarser cell keeps position → cell monotonic, which is what makes
        // the query a superset rather than a lottery.
        //
        // Spans are computed in Double because two legitimately finite `Float`
        // extremes are far enough apart that their difference overflows Float.
        let spanX = Double(maxX) - Double(minX)
        let spanY = Double(maxY) - Double(minY)
        var cell = Double(requestedCell)
        let widest = max(spanX, spanY) / cell
        let cap = Double(Self.maximumAxisCells - 1)
        if widest > cap { cell *= widest / cap }

        self.cellSize = Float(cell)
        origin = SIMD2(minX, minY)
        columns = min(Self.maximumAxisCells, max(1, Int((spanX / cell).rounded(.down)) + 1))
        rows = min(Self.maximumAxisCells, max(1, Int((spanY / cell).rounded(.down)) + 1))

        let cellCount = columns * rows
        var counts = [Int32](repeating: 0, count: cellCount)
        var cellOf = [Int32](repeating: 0, count: positions.count)

        for (index, p) in positions.enumerated() {
            let column = min(columns - 1, max(0, floorToInt((p.x - minX) / self.cellSize)))
            let row = min(rows - 1, max(0, floorToInt((p.y - minY) / self.cellSize)))
            let cell = Int32(row * columns + column)
            cellOf[index] = cell
            counts[Int(cell)] += 1
        }

        var offsets = [Int32](repeating: 0, count: cellCount + 1)
        for i in 0..<cellCount { offsets[i + 1] = offsets[i] + counts[i] }
        var items = [Int32](repeating: 0, count: positions.count)
        var cursor = offsets
        for index in 0..<positions.count {
            let cell = Int(cellOf[index])
            items[Int(cursor[cell])] = Int32(index)
            cursor[cell] += 1
        }

        bucketOffsets = offsets
        bucketItems = items
    }

    /// Every node whose cell intersects `rect`. A superset of what is visible,
    /// which is exactly what a cull wants — cheap and never drops something it
    /// should have drawn.
    func items(in rect: CGRect) -> [Int32] {
        guard columns > 0 else { return [] }
        // Saturating, not plain `Int(...)`: this rect comes from the camera,
        // which the user drives directly. Zoom far enough out and the visible
        // rect legitimately grows past what `Int` can hold.
        let minColumn = max(0, floorToInt((Float(rect.minX) - origin.x) / cellSize))
        let maxColumn = min(columns - 1, floorToInt((Float(rect.maxX) - origin.x) / cellSize))
        let minRow = max(0, floorToInt((Float(rect.minY) - origin.y) / cellSize))
        let maxRow = min(rows - 1, floorToInt((Float(rect.maxY) - origin.y) / cellSize))
        guard minColumn <= maxColumn, minRow <= maxRow else { return [] }

        var out: [Int32] = []
        out.reserveCapacity((maxColumn - minColumn + 1) * (maxRow - minRow + 1) * 4)
        for row in minRow...maxRow {
            let base = row * columns
            for column in minColumn...maxColumn {
                let cell = base + column
                out.append(contentsOf: bucketItems[Int(bucketOffsets[cell])..<Int(bucketOffsets[cell + 1])])
            }
        }
        return out
    }

    /// The nearest node to `point` within `radius`, or nil.
    func nearest(to point: SIMD2<Float>, within radius: Float, positions: [SIMD2<Float>]) -> Int? {
        let probe = CGRect(
            x: CGFloat(point.x - radius), y: CGFloat(point.y - radius),
            width: CGFloat(radius * 2), height: CGFloat(radius * 2)
        )
        var best: Int?
        var bestDistance = radius * radius
        for candidate in items(in: probe) {
            let delta = positions[Int(candidate)] - point
            let distance = delta.x * delta.x + delta.y * delta.y
            if distance <= bestDistance {
                bestDistance = distance
                best = Int(candidate)
            }
        }
        return best
    }
}
