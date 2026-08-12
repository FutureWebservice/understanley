import Foundation

/// Barnes-Hut force-directed layout — the Universe view's geometry.
///
/// Three forces, matching the constants upstream's d3 configuration uses:
/// links pull connected nodes together, charge pushes everything apart, and a
/// per-layer clustering force pulls each constellation toward its own point on
/// a circle. That last one is what makes layers read as separate regions of
/// space rather than one uniform cloud.
///
/// The quadtree turns the repulsion pass from O(n²) into O(n log n), which is
/// the difference between a second and a minute at 10 000 nodes.
enum ForceLayout {
    /// Above this node count the graph needs more room to breathe, so link
    /// distance and repulsion both increase. Same cutoff upstream uses.
    private static let largeGraphCutoff = 100

    static func compute(
        _ arrays: GraphArrays,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [SIMD2<Float>] {
        let n = arrays.count
        guard n > 0 else { return [] }
        guard n > 1 else { return [.zero] }

        let isLarge = n > largeGraphCutoff
        let linkDistance: Float = isLarge ? 250 : 150
        let linkStrength: Float = 0.2
        let chargeStrength: Float = isLarge ? -600 : -350
        let chargeDistanceMax: Float = 1500
        let centerStrength: Float = 0.03
        let clusterStrength: Float = 0.3
        let ticks = min(300, max(100, n))

        // Repulsion goes as 1/d², so two nearly-coincident bodies generate an
        // effectively unbounded force. Left alone the simulation diverges:
        // positions reach infinity, `inf - inf` produces NaN, and every
        // downstream consumer either draws nothing or traps converting the
        // bounds to an integer. Two bounds prevent it — a floor on the distance
        // used for repulsion, and a ceiling on how far anything may move in one
        // tick.
        let minimumRepulsionDistance: Float = 24
        let maximumStep: Float = 400

        // ── Seed positions ──
        //
        // Phyllotaxis rather than random: it fills space evenly, has no
        // clumping to untangle, and — crucially — is deterministic, so the same
        // graph always produces the same picture. A seeded RNG would do too,
        // but this needs no state at all.
        var positions = [SIMD2<Float>](repeating: .zero, count: n)
        let seedRadius: Float = Float(n).squareRoot() * 30
        for i in 0..<n {
            let angle = Float(i) * Palette.goldenAngle * .pi / 180
            let radius = seedRadius * (Float(i) / Float(n)).squareRoot()
            positions[i] = SIMD2(cos(angle) * radius, sin(angle) * radius)
        }

        // ── Cluster anchors, one per layer, arranged on a circle ──
        let layerCount = max(1, arrays.layerNames.count)
        // Two anchors on a circle sit diametrically opposite, which stretches
        // the drawing into a flat bar. Clustering only earns its place once
        // there are enough layers for the ring to read as a ring.
        let useClustering = layerCount >= 3
        // Scaled by the square root of the node count, matching how the area a
        // graph needs grows — linear scaling flings small graphs apart and
        // leaves large ones overlapping.
        let clusterRadius = max(400, Float(n).squareRoot() * 110)
        var anchors = [SIMD2<Float>](repeating: .zero, count: layerCount)
        if useClustering {
            for layer in 0..<layerCount {
                let angle = Float(layer) / Float(layerCount) * 2 * .pi
                anchors[layer] = SIMD2(cos(angle) * clusterRadius, sin(angle) * clusterRadius)
            }
        }

        var velocities = [SIMD2<Float>](repeating: .zero, count: n)
        let radii = arrays.radii

        for tick in 0..<ticks {
            if tick % 16 == 0, isCancelled() { break }

            // Simulated annealing: large steps early to untangle, small steps
            // late to settle. Without the decay the layout jitters forever
            // instead of converging.
            let alpha = 1 - Float(tick) / Float(ticks)
            let damping: Float = 0.82

            // ── Repulsion, via quadtree ──
            let tree = QuadTree(positions: positions)
            for i in 0..<n {
                let force = tree.repulsion(
                    at: positions[i], index: i,
                    strength: chargeStrength, maxDistance: chargeDistanceMax,
                    minDistance: minimumRepulsionDistance
                )
                velocities[i] += force * alpha
            }

            // ── Link attraction ──
            for e in 0..<arrays.edgeCount {
                let a = Int(arrays.edgeSource[e])
                let b = Int(arrays.edgeTarget[e])
                var delta = positions[b] - positions[a]
                var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                if distance < 0.001 {
                    // Coincident nodes have no direction to separate along;
                    // nudge deterministically so the pair does not stay fused.
                    delta = SIMD2(Float((a % 7) + 1) * 0.1, Float((b % 5) + 1) * 0.1)
                    distance = 0.5
                }
                let displacement = (distance - linkDistance) / distance * linkStrength * alpha
                let push = delta * displacement * 0.5
                velocities[a] += push
                velocities[b] -= push
            }

            // ── Clustering ──
            for i in 0..<n {
                let layer = arrays.layerIndex[i]
                if useClustering, layer >= 0, Int(layer) < anchors.count {
                    velocities[i] += (anchors[Int(layer)] - positions[i])
                        * (clusterStrength * alpha * 0.05)
                }
            }

            // ── Integrate ──
            for i in 0..<n {
                velocities[i] *= damping
                velocities[i] = clamp(velocities[i], to: maximumStep)
                positions[i] += velocities[i]
            }

            // ── Recentre ──
            //
            // d3's `forceCenter` *translates* the system so its centroid sits
            // at the target; it does not attract toward it. Implementing it as
            // an attraction — the obvious reading of the name — adds a force
            // pulling every node inward on every tick, which fights repulsion
            // and collapses the whole layout into a dense blob.
            var centroid = SIMD2<Float>.zero
            for p in positions { centroid += p }
            centroid /= Float(n)
            let shift = centroid * centerStrength
            for i in 0..<n { positions[i] -= shift }

            collide(&positions, radii: radii, strength: 0.8 * alpha)
        }

        // Overlap is a hard constraint, not a force: a halo drawn on top of
        // another halo is unreadable however good the rest of the layout is.
        // A few unweighted relaxation passes at the end enforce it once the
        // simulation has settled.
        // Each pass resolves the pairs it sees, but pushing two bodies apart
        // can push one into a third. Sixteen passes is where the count stops
        // improving on a dense graph, and the pass is grid-bucketed so it costs
        // almost nothing.
        for _ in 0..<16 {
            collide(&positions, radii: radii, strength: 1)
        }

        // Last line of defence. Even with the bounds above, a pathological
        // graph could still produce a non-finite coordinate, and the renderer
        // has no way to draw one — a single NaN silently blanks the canvas.
        // Anything unusable is replaced deterministically rather than left to
        // corrupt the view.
        sanitise(&positions, fallbackRadius: seedRadius)
        return positions
    }

    /// Caps a vector's magnitude, preserving direction.
    private static func clamp(_ vector: SIMD2<Float>, to maximum: Float) -> SIMD2<Float> {
        guard vector.x.isFinite, vector.y.isFinite else { return .zero }
        let magnitude = (vector.x * vector.x + vector.y * vector.y).squareRoot()
        guard magnitude > maximum, magnitude > 0 else { return vector }
        return vector / magnitude * maximum
    }

    /// Replaces any non-finite position with a point on a deterministic spiral,
    /// so the node still appears somewhere sensible instead of vanishing.
    private static func sanitise(_ positions: inout [SIMD2<Float>], fallbackRadius: Float) {
        for i in positions.indices where !(positions[i].x.isFinite && positions[i].y.isFinite) {
            let angle = Float(i) * Palette.goldenAngle * .pi / 180
            let radius = fallbackRadius * (Float(i + 1) / Float(positions.count + 1)).squareRoot()
            positions[i] = SIMD2(cos(angle) * radius, sin(angle) * radius)
        }
    }

    /// Pushes overlapping bodies apart so glow halos stay legible.
    private static func collide(
        _ positions: inout [SIMD2<Float>], radii: [Float], strength: Float
    ) {
        let n = positions.count
        // Grid-bucketed rather than all-pairs: only bodies sharing or adjoining
        // a cell can possibly overlap.
        let cell: Float = 90
        var buckets: [Int64: [Int32]] = [:]
        buckets.reserveCapacity(n)
        for i in 0..<n {
            let key = Self.cellKey(positions[i], cell: cell)
            buckets[key, default: []].append(Int32(i))
        }

        for i in 0..<n {
            let p = positions[i]
            let column = cellCoordinate(p.x, cell: cell)
            let row = cellCoordinate(p.y, cell: cell)
            for dx in -1...1 {
                for dy in -1...1 {
                    let key = ((column + Int64(dx)) << 32) ^ (row + Int64(dy))
                    guard let bucket = buckets[key] else { continue }
                    for rawJ in bucket {
                        let j = Int(rawJ)
                        guard j > i else { continue }
                        let minimum = (radii[i] + radii[j]) * 1.6 + 12
                        var delta = positions[j] - positions[i]
                        var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
                        guard distance < minimum else { continue }
                        if distance < 0.001 {
                            delta = SIMD2(Float(i % 3) + 0.5, Float(j % 3) + 0.5)
                            distance = 1
                        }
                        let push = delta / distance * ((minimum - distance) * 0.5 * strength)
                        positions[i] -= push
                        positions[j] += push
                    }
                }
            }
        }
    }

    private static func cellKey(_ p: SIMD2<Float>, cell: Float) -> Int64 {
        (cellCoordinate(p.x, cell: cell) << 32) ^ cellCoordinate(p.y, cell: cell)
    }

    /// One grid axis, total by construction.
    ///
    /// This runs *inside* the simulation loop, where positions have not been
    /// through `sanitise` yet — so unlike the returned layout, nothing upstream
    /// guarantees the value is usable. The velocity clamp should keep
    /// coordinates small, but "should" is exactly what an earlier version of
    /// this file crashed on.
    private static func cellCoordinate(_ value: Float, cell: Float) -> Int64 {
        Int64(floorToInt(value / cell))
    }
}

// MARK: - Quadtree

/// Barnes-Hut quadtree over node positions.
///
/// Repulsion between every pair is O(n²) and dominates the simulation. The
/// quadtree approximates a distant cluster of bodies by its centre of mass,
/// which is indistinguishable at that distance and turns each pass into
/// O(n log n).
struct QuadTree {
    private struct Node {
        var centreOfMass: SIMD2<Float> = .zero
        var mass: Float = 0
        var bounds: (origin: SIMD2<Float>, size: Float) = (.zero, 0)
        /// Indices into `nodes`, or -1. Order: NW, NE, SW, SE.
        var children: SIMD4<Int32> = SIMD4(repeating: -1)
        /// Index of the single body in a leaf, or -1.
        var body: Int32 = -1
        var isLeaf: Bool { children[0] < 0 }
    }

    private var nodes: [Node] = []
    private let positions: [SIMD2<Float>]

    /// Opening angle. Below this ratio of cell size to distance, a cell is
    /// treated as one body. 0.5 is the classical value and is visually
    /// indistinguishable from exact computation.
    private let theta: Float = 0.5

    init(positions: [SIMD2<Float>]) {
        self.positions = positions
        guard !positions.isEmpty else { return }

        var minX = positions[0].x, maxX = positions[0].x
        var minY = positions[0].y, maxY = positions[0].y
        for p in positions {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let size = max(max(maxX - minX, maxY - minY), 1) * 1.05

        nodes.reserveCapacity(positions.count * 2)
        nodes.append(Node(bounds: (SIMD2(minX, minY), size)))
        for index in positions.indices {
            insert(Int32(index), into: 0, depth: 0)
        }
    }

    private mutating func insert(_ body: Int32, into nodeIndex: Int, depth: Int) {
        // Depth cap: coincident or near-coincident points would otherwise
        // subdivide forever. At depth 24 the cell is smaller than any distance
        // that matters.
        guard depth < 24 else {
            nodes[nodeIndex].mass += 1
            return
        }

        if nodes[nodeIndex].isLeaf {
            if nodes[nodeIndex].body < 0 {
                nodes[nodeIndex].body = body
                nodes[nodeIndex].centreOfMass = positions[Int(body)]
                nodes[nodeIndex].mass = 1
                return
            }
            // Split, then re-insert the body that was already here.
            let existing = nodes[nodeIndex].body
            nodes[nodeIndex].body = -1
            subdivide(nodeIndex)
            place(existing, in: nodeIndex, depth: depth)
            place(body, in: nodeIndex, depth: depth)
        } else {
            place(body, in: nodeIndex, depth: depth)
        }

        // Running centre of mass for the subtree.
        let mass = nodes[nodeIndex].mass
        let point = positions[Int(body)]
        nodes[nodeIndex].centreOfMass =
            (nodes[nodeIndex].centreOfMass * mass + point) / (mass + 1)
        nodes[nodeIndex].mass = mass + 1
    }

    private mutating func subdivide(_ nodeIndex: Int) {
        let (origin, size) = nodes[nodeIndex].bounds
        let half = size / 2
        var children = SIMD4<Int32>(repeating: -1)
        let offsets: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(half, 0), SIMD2(0, half), SIMD2(half, half),
        ]
        for quadrant in 0..<4 {
            nodes.append(Node(bounds: (origin + offsets[quadrant], half)))
            children[quadrant] = Int32(nodes.count - 1)
        }
        nodes[nodeIndex].children = children
    }

    private mutating func place(_ body: Int32, in nodeIndex: Int, depth: Int) {
        let (origin, size) = nodes[nodeIndex].bounds
        let half = size / 2
        let p = positions[Int(body)]
        let east = p.x >= origin.x + half ? 1 : 0
        let south = p.y >= origin.y + half ? 2 : 0
        let child = Int(nodes[nodeIndex].children[east + south])
        guard child >= 0 else { return }
        insert(body, into: child, depth: depth + 1)
    }

    /// Net repulsive force on the body at `point`.
    func repulsion(
        at point: SIMD2<Float>, index: Int, strength: Float,
        maxDistance: Float, minDistance: Float
    ) -> SIMD2<Float> {
        guard !nodes.isEmpty, point.x.isFinite, point.y.isFinite else { return .zero }
        var force = SIMD2<Float>.zero
        var stack: [Int32] = [0]

        while let rawIndex = stack.popLast() {
            let node = nodes[Int(rawIndex)]
            guard node.mass > 0 else { continue }
            if node.body == Int32(index), node.mass == 1 { continue }

            var delta = node.centreOfMass - point
            var distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
            // `!(x < y)` rather than `x >= y`, so a NaN distance is skipped
            // instead of sailing through every comparison and poisoning the
            // accumulator.
            guard distance.isFinite else { continue }
            if distance > maxDistance { continue }
            if distance < minDistance {
                // Deterministic jitter so two bodies at the same point still
                // separate, without introducing randomness. The distance floor
                // also caps the 1/d² term, which is what keeps the simulation
                // from diverging.
                if distance < 0.001 {
                    delta = SIMD2(Float((index % 11) - 5), Float((index % 7) - 3))
                }
                distance = minDistance
            }

            // Far enough away, or a leaf: treat as a single body.
            if node.isLeaf || node.bounds.size / distance < theta {
                let magnitude = strength * node.mass / (distance * distance)
                force += delta / distance * magnitude
                continue
            }
            for quadrant in 0..<4 where node.children[quadrant] >= 0 {
                stack.append(node.children[quadrant])
            }
        }
        return force
    }
}
