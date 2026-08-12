import XCTest

@testable import Understanley

/// Layout invariants.
///
/// These exist because a broken layout does not throw — it renders a blank
/// canvas, or a graph the width of a city block, and the only symptom is that
/// the app "looks wrong". Every check here corresponds to a failure mode that
/// actually occurred while building it.
final class LayoutTests: XCTestCase {
    /// A synthetic graph with hubs, chains, isolated nodes and a cycle — the
    /// shapes that break layout code.
    private func makeGraph(nodeCount: Int, layerCount: Int = 3) -> GraphArrays {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for i in 0..<nodeCount {
            nodes.append(GraphNode(
                id: "file:n\(i).ts", type: .file, name: "n\(i).ts",
                filePath: "n\(i).ts", summary: "s", tags: ["t"],
                complexity: i % 3 == 0 ? .complex : .simple
            ))
        }
        // A hub every tenth node, so degree varies the way it does in real code.
        // `stride` rather than a range: the degenerate cases pass nodeCount 0,
        // and `1..<0` traps.
        for i in stride(from: 1, to: nodeCount, by: 1) {
            let target = (i / 10) * 10
            if target != i {
                edges.append(GraphEdge(source: "file:n\(i).ts", target: "file:n\(target).ts",
                                       type: .imports))
            }
        }
        // Chain the hubs together, so the graph has routes longer than one hop
        // for the path finder to actually find.
        for hub in stride(from: 10, to: nodeCount, by: 10) {
            edges.append(GraphEdge(source: "file:n\(hub - 10).ts", target: "file:n\(hub).ts",
                                   type: .imports))
        }

        // A cycle, which a naive ranking pass would loop on forever.
        if nodeCount > 3 {
            edges.append(GraphEdge(source: "file:n1.ts", target: "file:n2.ts", type: .imports))
            edges.append(GraphEdge(source: "file:n2.ts", target: "file:n3.ts", type: .imports))
            edges.append(GraphEdge(source: "file:n3.ts", target: "file:n1.ts", type: .imports))
        }

        let layers = (0..<layerCount).map { layer in
            Layer(
                id: "layer:l\(layer)", name: "Layer \(layer)", description: "",
                nodeIds: (0..<nodeCount).filter { $0 % layerCount == layer }.map { "file:n\($0).ts" }
            )
        }
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "t", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: ""),
            nodes: nodes, edges: edges, layers: layers, tour: []
        )
        return GraphArrays.compile(graph)
    }

    private func assertAllFinite(_ positions: [SIMD2<Float>], _ label: String) {
        for (index, p) in positions.enumerated() {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite,
                          "\(label): node \(index) is at a non-finite position (\(p.x), \(p.y))")
        }
    }

    // MARK: - Correctness

    func testBothLayoutsProduceFinitePositions() {
        // The force simulation diverged to infinity before the step clamp and
        // distance floor were added, and `inf - inf` then produced NaN. The
        // only visible symptom was a blank canvas.
        let arrays = makeGraph(nodeCount: 400)
        assertAllFinite(LayeredLayout.compute(arrays).positions, "Blueprint")
        assertAllFinite(ForceLayout.compute(arrays), "Universe")
    }

    func testLayoutsAreDeterministic() {
        let arrays = makeGraph(nodeCount: 120)
        XCTAssertEqual(LayeredLayout.compute(arrays).positions,
                       LayeredLayout.compute(arrays).positions)
        // Determinism is what lets the morph interpolate between two layouts
        // computed at different times, and what makes these tests possible.
        XCTAssertEqual(ForceLayout.compute(arrays), ForceLayout.compute(arrays))
    }

    func testLayeredLayoutTerminatesOnCycles() {
        // Kahn's algorithm alone never drains a cyclic graph. Import cycles are
        // common enough that refusing to lay one out means refusing most real
        // projects.
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for i in 0..<6 {
            nodes.append(GraphNode(id: "file:c\(i).ts", type: .file, name: "c\(i)",
                                   filePath: "c\(i).ts", summary: "s", tags: ["t"]))
            edges.append(GraphEdge(source: "file:c\(i).ts",
                                   target: "file:c\((i + 1) % 6).ts", type: .imports))
        }
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "t", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: ""),
            nodes: nodes, edges: edges,
            layers: [Layer(id: "layer:core", name: "Core", description: "",
                           nodeIds: nodes.map(\.id))],
            tour: []
        )
        let arrays = GraphArrays.compile(graph)
        let result = LayeredLayout.compute(arrays)
        assertAllFinite(result.positions, "cyclic")
        // Every node got a rank rather than being dropped.
        XCTAssertTrue(result.ranks.allSatisfy { $0 >= 0 })
    }

    func testBlueprintKeepsAReadableAspectRatio() {
        // Dependency graphs are lopsided: most files import nothing, so one
        // rank holds hundreds of nodes. Without wrapping the drawing came out
        // 39 780 × 2 000 — correct, and unusable.
        let arrays = makeGraph(nodeCount: 500)
        let positions = LayeredLayout.compute(arrays).positions
        let bounds = GraphArrays.bounds(of: positions, padding: 0)
        let aspect = bounds.width / bounds.height
        // This fixture is a fifty-deep hub chain, so it is legitimately tall —
        // height in a layered drawing means dependency depth. The pathology
        // being guarded against is the other direction: before wrapping, a real
        // project came out 39 780 × 2 000.
        XCTAssertTrue(aspect > 0.2 && aspect < 3.5,
                      "aspect ratio \(aspect) is not screen-shaped "
                      + "(\(Int(bounds.width))×\(Int(bounds.height)))")
    }

    func testBlueprintDoesNotOverlapNodes() {
        // Ranks and columns are on a fixed grid, so overlap here means the
        // wrapping arithmetic is wrong.
        let arrays = makeGraph(nodeCount: 300)
        let positions = LayeredLayout.compute(arrays).positions
        var seen = Set<String>()
        for p in positions {
            let key = "\(Int(p.x / 10))|\(Int(p.y / 10))"
            XCTAssertTrue(seen.insert(key).inserted, "two nodes share a cell at \(p)")
        }
    }

    func testUniverseSpreadsRatherThanCollapsing() {
        // Implementing d3's `forceCenter` as an attraction rather than a
        // translation collapsed the whole layout into a dense bar.
        let arrays = makeGraph(nodeCount: 300)
        let positions = ForceLayout.compute(arrays)
        let bounds = GraphArrays.bounds(of: positions, padding: 0)
        XCTAssertGreaterThan(bounds.width, 500)
        XCTAssertGreaterThan(bounds.height, 500)
        let aspect = bounds.width / bounds.height
        XCTAssertTrue(aspect > 0.3 && aspect < 3.3, "collapsed to aspect \(aspect)")
    }

    /// `Int(someFloat)` traps rather than saturating, and the spatial index
    /// converts both node positions and the camera rect. The camera is driven
    /// by live user input, so "the value is always in range" is an assumption
    /// about a human's scroll wheel — which is not an assumption at all.
    /// An earlier build died exactly this way inside the force simulation.
    func testSpatialIndexSurvivesUnusableGeometry() {
        let poison: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(100, 100),
            SIMD2(.nan, 5), SIMD2(5, .nan),
            SIMD2(.infinity, 0), SIMD2(-.infinity, 0),
            SIMD2(.greatestFiniteMagnitude, .greatestFiniteMagnitude),
            SIMD2(-.greatestFiniteMagnitude, 1e30),
        ]
        let index = SpatialIndex(positions: poison)

        // The two ordinary nodes sit at the origin. A single absurd outlier
        // must not push them out of reach: the grid coarsens to fit the extent,
        // but position → cell has to stay consistent between the build and the
        // query. When it does not, every lookup misses and the canvas renders
        // empty with nothing logged anywhere.
        let nearOrigin = index.items(in: CGRect(x: -1e9, y: -1e9, width: 2e9, height: 2e9))
        XCTAssertTrue(nearOrigin.contains(0), "lost the node at (0, 0)")
        XCTAssertTrue(nearOrigin.contains(1), "lost the node at (100, 100)")

        // And the query side, which is what the camera actually calls.
        let sane = SpatialIndex(positions: [SIMD2(0, 0), SIMD2(50, 50), SIMD2(900, 900)])
        for rect in [
            CGRect(x: -CGFloat.greatestFiniteMagnitude / 2,
                   y: -CGFloat.greatestFiniteMagnitude / 2,
                   width: CGFloat.greatestFiniteMagnitude,
                   height: CGFloat.greatestFiniteMagnitude),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: CGFloat.infinity),
            CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 10, height: 10),
            CGRect(x: -1e300, y: -1e300, width: 2e300, height: 2e300),
        ] {
            _ = sane.items(in: rect)  // must return, not trap
        }
    }

    func testDegenerateGraphsDoNotCrash() {
        for count in [0, 1, 2] {
            let arrays = makeGraph(nodeCount: count, layerCount: 1)
            assertAllFinite(LayeredLayout.compute(arrays).positions, "layered \(count)")
            assertAllFinite(ForceLayout.compute(arrays), "force \(count)")
        }
    }

    func testCoincidentNodesSeparate() {
        // Every node starts at the origin only if the seed is broken, but a
        // graph with no edges exercises the same divide-by-zero paths.
        var nodes: [GraphNode] = []
        for i in 0..<40 {
            nodes.append(GraphNode(id: "file:x\(i).ts", type: .file, name: "x",
                                   filePath: "x\(i).ts", summary: "s", tags: ["t"]))
        }
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "t", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: ""),
            nodes: nodes, edges: [], layers: [], tour: []
        )
        let positions = ForceLayout.compute(GraphArrays.compile(graph))
        assertAllFinite(positions, "isolated")
        XCTAssertGreaterThan(GraphArrays.bounds(of: positions, padding: 0).width, 10)
    }

    // MARK: - Adjacency and index

    func testAdjacencyIsSymmetricAndComplete() {
        let arrays = makeGraph(nodeCount: 60)
        for e in 0..<arrays.edgeCount {
            let a = Int(arrays.edgeSource[e])
            let b = Int(arrays.edgeTarget[e])
            XCTAssertTrue(arrays.neighbours(of: a).contains(Int32(b)))
            XCTAssertTrue(arrays.neighbours(of: b).contains(Int32(a)))
        }
        for i in 0..<arrays.count {
            XCTAssertEqual(Int(arrays.degree[i]), arrays.neighbours(of: i).count)
        }
    }

    func testShortestPathFindsAConnectedRoute() {
        let arrays = makeGraph(nodeCount: 60)
        let path = arrays.shortestPath(from: 11, to: 21)
        XCTAssertFalse(path.isEmpty, "no route between two connected hubs")
        XCTAssertEqual(path.first, 11)
        XCTAssertEqual(path.last, 21)
        // Every consecutive pair must actually be adjacent.
        for (a, b) in zip(path, path.dropFirst()) {
            XCTAssertTrue(arrays.neighbours(of: a).contains(Int32(b)))
        }
    }

    func testSpatialIndexLocatesEveryNode() {
        // Culling and hit-testing both go through this. A node the index cannot
        // find is a node the user cannot click.
        let arrays = makeGraph(nodeCount: 300)
        let positions = ForceLayout.compute(arrays)
        let index = SpatialIndex(positions: positions)
        for i in 0..<positions.count {
            XCTAssertNotNil(index.nearest(to: positions[i], within: 1, positions: positions),
                            "node \(i) is unreachable through the spatial index")
        }
    }

    // MARK: - Camera

    func testCameraZoomAnchorsOnTheCursor() {
        // Zooming toward the view centre instead of the pointer is immediately
        // noticeable and makes the canvas feel like it is fighting you.
        let viewport = CGSize(width: 1000, height: 800)
        var camera = Camera(centre: .zero, zoom: 1)
        let anchor = CGPoint(x: 250, y: 200)
        let before = camera.screenToWorld(anchor, viewport: viewport)
        camera.zoom(by: 2.5, anchor: anchor, viewport: viewport)
        let after = camera.screenToWorld(anchor, viewport: viewport)
        XCTAssertEqual(before.x, after.x, accuracy: 0.01)
        XCTAssertEqual(before.y, after.y, accuracy: 0.01)
    }

    func testCameraZoomStaysInBounds() {
        let viewport = CGSize(width: 1000, height: 800)
        var camera = Camera()
        for _ in 0..<50 { camera.zoom(by: 4, anchor: .zero, viewport: viewport) }
        XCTAssertLessThanOrEqual(camera.zoom, Camera.maxZoom)
        for _ in 0..<200 { camera.zoom(by: 0.25, anchor: .zero, viewport: viewport) }
        XCTAssertGreaterThanOrEqual(camera.zoom, Camera.minZoom)
    }

    func testFittingFramesTheWholeGraph() {
        let viewport = CGSize(width: 1200, height: 800)
        let rect = CGRect(x: -500, y: -400, width: 4000, height: 2000)
        let camera = Camera.fitting(rect, viewport: viewport)
        let visible = camera.visibleWorldRect(viewport: viewport, margin: 0)
        XCTAssertTrue(visible.contains(rect), "fit left part of the graph off screen")
    }

    func testRoundTripBetweenScreenAndWorld() {
        let viewport = CGSize(width: 900, height: 600)
        let camera = Camera(centre: SIMD2(120, -80), zoom: 0.37)
        let screen = CGPoint(x: 321, y: 145)
        let back = camera.worldToScreen(camera.screenToWorld(screen, viewport: viewport),
                                        viewport: viewport)
        XCTAssertEqual(screen.x, back.x, accuracy: 0.01)
        XCTAssertEqual(screen.y, back.y, accuracy: 0.01)
    }

    // MARK: - Palette

    func testLayerHuesAreWellSeparated() {
        // Golden-angle spacing should keep adjacent layers distinguishable for
        // any number of layers, which an evenly-divided wheel cannot do without
        // knowing the count up front.
        let hues = (0..<8).map { Palette.layerHue($0) }
        for i in 0..<hues.count {
            for j in (i + 1)..<hues.count {
                let raw = abs(hues[i] - hues[j])
                let separation = min(raw, 360 - raw)
                XCTAssertGreaterThan(separation, 18,
                                     "layers \(i) and \(j) are only \(separation)° apart")
            }
        }
    }

    func testRadiusGrowsWithDegreeButStaysBounded() {
        XCTAssertLessThan(Palette.radius(degree: 0), Palette.radius(degree: 50))
        XCTAssertLessThanOrEqual(Palette.radius(degree: 100_000), 28)
    }
}

/// What a Blueprint card shows at a given on-screen size.
///
/// These exist because the original bug was invisible in review and obvious on
/// screen: every card on a project small enough to fit the window rendered as
/// an empty rectangle. The gate was the camera zoom rather than how big the
/// card actually ended up.
final class CardLayoutTests: XCTestCase {
    private func plan(_ w: CGFloat, _ h: CGFloat,
                      summary: Bool = true, complex: Bool = true, tested: Bool = true)
        -> CardLayout {
        CardLayout.forCard(width: w, height: h, hasSummary: summary,
                           isComplex: complex, isTested: tested)
    }

    func testWholeProjectFitStillShowsTheName() {
        // ~83x31pt is what a card measures when a 48-file project is fitted to
        // the window. This is the exact case that used to render blank.
        let p = plan(83, 31)
        XCTAssertTrue(p.showsName)
        XCTAssertGreaterThanOrEqual(p.nameSize, 9, "text must stay readable, not scale to nothing")
        XCTAssertFalse(p.showsType, "no room for a type line at this height")
        XCTAssertFalse(p.showsSummary)
        XCTAssertGreaterThan(p.nameBudget, 6)
    }

    func testDetailAppearsOneLineAtATimeAsTheCardGrows() {
        XCTAssertFalse(plan(120, 40).showsType)
        // 60pt would put the type line at ~6pt — drawn, unreadable. Not worth it.
        XCTAssertFalse(plan(160, 60).showsType)
        XCTAssertTrue(plan(200, 80).showsType)
        XCTAssertFalse(plan(200, 80).showsSummary, "type arrives before summary, not with it")
        XCTAssertTrue(plan(280, 104).showsSummary)
    }

    func testNothingIsDrawnOnACardTooSmallToHoldIt() {
        XCTAssertFalse(plan(20, 10).showsName)
        XCTAssertFalse(plan(300, 11).showsName, "wide but far too short")
    }

    func testBadgesNeedTheirOwnRoom() {
        XCTAssertFalse(plan(50, 90, tested: true).showsTestedDot, "too narrow for a dot")
        XCTAssertTrue(plan(200, 90, tested: true).showsTestedDot)
        // The chip rides the type line, so it cannot appear without one.
        XCTAssertFalse(plan(200, 30, complex: true).showsComplexityChip)
        XCTAssertTrue(plan(200, 100, complex: true).showsComplexityChip)
        XCTAssertFalse(plan(200, 100, complex: false).showsComplexityChip)
    }

    func testSummaryIsNotPromisedWhenThereIsNone() {
        XCTAssertFalse(plan(280, 104, summary: false).showsSummary)
    }
}

