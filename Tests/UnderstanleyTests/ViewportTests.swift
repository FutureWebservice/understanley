import XCTest

@testable import Understanley

/// Camera framing under the ordering SwiftUI actually gives us.
///
/// The bug these guard against was invisible to every other test: the graph
/// loaded, the layout was correct, the tests passed — and the picture arrived
/// off-screen, because the initial fit ran against a viewport that did not
/// exist yet.
@MainActor
final class ViewportTests: XCTestCase {
    private func makeGraph(spread: Float) -> KnowledgeGraph {
        var nodes: [GraphNode] = []
        for i in 0..<20 {
            nodes.append(GraphNode(
                id: "file:n\(i).ts", type: .file, name: "n\(i).ts", filePath: "n\(i).ts",
                summary: "s", tags: ["t"]
            ))
        }
        _ = spread
        return KnowledgeGraph(
            project: ProjectMeta(name: "p", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: "abc"),
            nodes: nodes, edges: [],
            layers: [Layer(id: "layer:core", name: "Core", description: "",
                           nodeIds: nodes.map(\.id))],
            tour: []
        )
    }

    func testFitIsDeferredUntilAViewportExists() async throws {
        // The real ordering: `load` runs from a parent's `onAppear`, which
        // fires BEFORE the child GeometryReader has reported a size. Fitting
        // eagerly here is what produced a camera framed for a made-up window.
        let model = GraphViewModel()
        model.load(makeGraph(spread: 4000), entryPoint: nil)

        // Let the layout task finish.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(model.isLayingOut, "layout should have completed")

        // No viewport yet — the camera must not have been framed against a guess.
        XCTAssertEqual(model.camera.zoom, Camera().zoom, accuracy: 0.0001,
                       "camera was fitted before a viewport was known")

        // Now the canvas reports its real size.
        model.setViewport(CGSize(width: 1600, height: 900))

        let bounds = GraphArrays.bounds(of: model.displayPositions)
        let visible = model.camera.visibleWorldRect(
            viewport: CGSize(width: 1600, height: 900), margin: 0
        )
        XCTAssertTrue(visible.contains(bounds),
                      "graph is not fully framed after the viewport arrives")
    }

    func testFitHappensImmediatelyWhenViewportIsAlreadyKnown() async throws {
        // Reopening a project, or switching graphs, hits the other ordering.
        let model = GraphViewModel()
        model.setViewport(CGSize(width: 1200, height: 800))
        model.load(makeGraph(spread: 2000), entryPoint: nil)
        try await Task.sleep(nanoseconds: 600_000_000)

        let bounds = GraphArrays.bounds(of: model.displayPositions)
        let visible = model.camera.visibleWorldRect(
            viewport: CGSize(width: 1200, height: 800), margin: 0
        )
        XCTAssertTrue(visible.contains(bounds), "graph is not framed on load")
    }

    func testZeroSizedViewportIsIgnored() {
        // SwiftUI reports a zero frame during the first layout pass. Accepting
        // it would divide by zero in the fit and leave a broken camera.
        let model = GraphViewModel()
        model.setViewport(.zero)
        XCTAssertEqual(model.viewport, .zero)
        model.setViewport(CGSize(width: 0, height: 500))
        XCTAssertEqual(model.viewport, .zero)
        model.setViewport(CGSize(width: 900, height: 600))
        XCTAssertEqual(model.viewport.width, 900)
    }

    func testHitTestWithoutAViewportReturnsNothing() {
        // Rather than computing world coordinates from a zero-sized view and
        // selecting whatever happens to be near the origin.
        let model = GraphViewModel()
        XCTAssertNil(model.hitTest(CGPoint(x: 10, y: 10)))
    }

    func testScrollIsAppliedOncePerFrameNotPerEvent() {
        // A trackpad emits scroll far faster than the display refreshes.
        // Accumulating and applying on tick is what keeps input rate from
        // driving redraw rate.
        let model = GraphViewModel()
        model.setViewport(CGSize(width: 1000, height: 800))
        let before = model.camera.centre

        for _ in 0..<10 {
            model.queueScroll(CGSize(width: 5, height: 0))
        }
        // Nothing has moved yet — the events are queued, not applied.
        XCTAssertEqual(model.camera.centre.x, before.x, accuracy: 0.001)

        model.tick(now: Date())
        // One frame applies the whole accumulated delta.
        XCTAssertNotEqual(model.camera.centre.x, before.x)
    }

    func testScrollKeepsFramesComingThenStops() {
        let model = GraphViewModel()
        model.setViewport(CGSize(width: 1000, height: 800))
        XCTAssertFalse(model.needsContinuousRedraw, "an idle Blueprint canvas should cost nothing")

        model.queueScroll(CGSize(width: 4, height: 4))
        XCTAssertTrue(model.needsContinuousRedraw, "scrolling must request frames")

        model.tick(now: Date())   // applies the delta
        model.tick(now: Date())   // nothing pending — settles
        XCTAssertFalse(model.needsContinuousRedraw, "canvas should go idle once scrolling stops")
    }

    func testSelectionNeighbourhoodIsCachedNotRecomputed() async throws {
        let model = GraphViewModel()
        model.setViewport(CGSize(width: 1000, height: 800))

        var graph = makeGraph(spread: 1000)
        graph.edges = [
            GraphEdge(source: "file:n0.ts", target: "file:n1.ts", type: .imports),
            GraphEdge(source: "file:n0.ts", target: "file:n2.ts", type: .imports),
        ]
        model.load(graph, entryPoint: nil)
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertNil(model.selectionNeighbourhood)
        model.select(0)
        // Node 0 plus its two neighbours.
        XCTAssertEqual(model.selectionNeighbourhood?.count, 3)
        model.select(nil)
        XCTAssertNil(model.selectionNeighbourhood)
    }
}

/// The code viewer's path guard.
///
/// This is the one place the app turns graph *content* into a file read, and
/// graph content is not necessarily trustworthy — a `.ua/knowledge-graph.json`
/// can come from another machine or another tool. Every case here is a way that
/// read could be pointed somewhere it should not go.
final class CodeViewerAccessTests: XCTestCase {
    private let allowed: Set<String> = [
        "src/main.ts", "app/adInit.js", "../../.ssh/id_rsa", "/etc/passwd",
    ]

    func testOpensOnlyPathsTheGraphLists() {
        XCTAssertTrue(CodeViewer.canOpen("src/main.ts", allowedPaths: allowed))
        XCTAssertTrue(CodeViewer.canOpen("app/adInit.js", allowedPaths: allowed))
        // Real file, but this graph never mentioned it.
        XCTAssertFalse(CodeViewer.canOpen("src/secret.ts", allowedPaths: allowed))
        XCTAssertFalse(CodeViewer.canOpen("", allowedPaths: allowed))
    }

    func testRefusesTraversalEvenWhenTheGraphListsIt() {
        // Both of these ARE in the allowlist. Being listed is not enough —
        // otherwise a hostile graph file turns the viewer into a way to read
        // anything the user can read.
        XCTAssertFalse(CodeViewer.canOpen("../../.ssh/id_rsa", allowedPaths: allowed))
        XCTAssertFalse(CodeViewer.canOpen("/etc/passwd", allowedPaths: allowed))
    }

    func testEmptyAllowlistOpensNothing() {
        XCTAssertFalse(CodeViewer.canOpen("src/main.ts", allowedPaths: []))
    }
}

/// What the auto-update watcher will and will not wake up for.
///
/// The `.ua` rule is the load-bearing one: the app writes the graph into that
/// directory itself, so without the filter a save triggers an analysis, which
/// writes the graph, which triggers another analysis — forever.
final class FileWatcherFilterTests: XCTestCase {
    func testIgnoresItsOwnOutputDirectory() {
        XCTAssertFalse(FileWatcher.isInteresting("/p/.ua/knowledge-graph.json"))
        XCTAssertFalse(FileWatcher.isInteresting("/p/.understand-anything/meta.json"))
    }

    func testIgnoresBuildAndVCSNoise() {
        for path in ["/p/.git/index", "/p/node_modules/react/index.js",
                     "/p/dist/bundle.js", "/p/.next/cache/x", "/p/target/debug/app",
                     "/p/__pycache__/m.pyc", "/p/.build/release/bin"] {
            XCTAssertFalse(FileWatcher.isInteresting(path), path)
        }
    }

    func testIgnoresEditorScratchFiles() {
        XCTAssertFalse(FileWatcher.isInteresting("/p/src/main.ts~"))
        XCTAssertFalse(FileWatcher.isInteresting("/p/src/.main.ts.swp"))
    }

    func testReactsToRealSourceEdits() {
        XCTAssertTrue(FileWatcher.isInteresting("/p/src/main.ts"))
        XCTAssertTrue(FileWatcher.isInteresting("/p/app/adInit.js"))
        XCTAssertTrue(FileWatcher.isInteresting("/p/README.md"))
    }
}

