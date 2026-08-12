import XCTest

@testable import Understanley

/// Blast-radius computation.
///
/// The question a diff view answers is not "which files did I edit" — git
/// already says that — but "what else might this break". Getting the direction
/// or the edge selection wrong produces an answer that looks authoritative and
/// is backwards.
final class DiffTests: XCTestCase {
    /// `app.ts → service.ts → model.ts`, plus an unrelated `docs.md` and a
    /// merely-similar `sibling.ts`.
    private func makeGraph() -> (KnowledgeGraph, GraphArrays) {
        let nodes = [
            GraphNode(id: "file:app.ts", type: .file, name: "app.ts", filePath: "app.ts",
                      summary: "s", tags: ["t"]),
            GraphNode(id: "file:service.ts", type: .file, name: "service.ts",
                      filePath: "service.ts", summary: "s", tags: ["t"]),
            GraphNode(id: "file:model.ts", type: .file, name: "model.ts", filePath: "model.ts",
                      summary: "s", tags: ["t"]),
            GraphNode(id: "file:sibling.ts", type: .file, name: "sibling.ts",
                      filePath: "sibling.ts", summary: "s", tags: ["t"]),
            GraphNode(id: "document:docs.md", type: .document, name: "docs.md",
                      filePath: "docs.md", summary: "s", tags: ["t"]),
        ]
        let edges = [
            GraphEdge(source: "file:app.ts", target: "file:service.ts", type: .imports),
            GraphEdge(source: "file:service.ts", target: "file:model.ts", type: .imports),
            // Resemblance, not dependency — must not propagate.
            GraphEdge(source: "file:sibling.ts", target: "file:model.ts", type: .related),
            // Documentation points at code but does not break when it changes.
            GraphEdge(source: "document:docs.md", target: "file:model.ts", type: .documents),
        ]
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "p", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: "abc"),
            nodes: nodes, edges: edges,
            layers: [Layer(id: "layer:core", name: "Core", description: "",
                           nodeIds: nodes.map(\.id))],
            tour: []
        )
        return (graph, GraphArrays.compile(graph))
    }

    private func ids(_ set: Set<Int32>, _ arrays: GraphArrays) -> Set<String> {
        Set(set.map { arrays.ids[Int($0)] })
    }

    func testChangeRipplesToDependentsNotDependencies() {
        let (graph, arrays) = makeGraph()
        let diff = DiffOverlay.compute(changedFiles: ["model.ts"], arrays: arrays, graph: graph)

        XCTAssertEqual(ids(diff.changed, arrays), ["file:model.ts"])
        // `service.ts` imports `model.ts`, and `app.ts` imports `service.ts`.
        // Both are downstream of the change.
        XCTAssertTrue(ids(diff.affected, arrays).contains("file:service.ts"))
        XCTAssertTrue(ids(diff.affected, arrays).contains("file:app.ts"))
    }

    func testSemanticEdgesDoNotPropagate() {
        // `related` and `documents` say two things resemble or describe each
        // other, not that one breaks when the other moves. Including them would
        // mark half the graph and make the feature useless.
        let (graph, arrays) = makeGraph()
        let diff = DiffOverlay.compute(changedFiles: ["model.ts"], arrays: arrays, graph: graph)
        XCTAssertFalse(ids(diff.affected, arrays).contains("file:sibling.ts"))
        XCTAssertFalse(ids(diff.affected, arrays).contains("document:docs.md"))
    }

    func testDependenciesOfAChangedFileAreNotAffected() {
        // Editing `app.ts` cannot break `service.ts` — the arrow points the
        // other way. Walking forwards instead of backwards would report exactly
        // the files that did not move.
        let (graph, arrays) = makeGraph()
        let diff = DiffOverlay.compute(changedFiles: ["app.ts"], arrays: arrays, graph: graph)
        XCTAssertEqual(ids(diff.changed, arrays), ["file:app.ts"])
        XCTAssertTrue(diff.affected.isEmpty, "dependencies were reported as affected")
    }

    func testDepthIsRespected() {
        let (graph, arrays) = makeGraph()
        let shallow = DiffOverlay.compute(
            changedFiles: ["model.ts"], arrays: arrays, graph: graph, depth: 1
        )
        // One hop reaches the direct importer only.
        XCTAssertTrue(ids(shallow.affected, arrays).contains("file:service.ts"))
        XCTAssertFalse(ids(shallow.affected, arrays).contains("file:app.ts"))
    }

    func testSubFileNodesOfAChangedFileCountAsChanged() {
        var nodes = [
            GraphNode(id: "file:a.ts", type: .file, name: "a.ts", filePath: "a.ts",
                      summary: "s", tags: ["t"]),
        ]
        nodes.append(GraphNode(id: "function:a.ts:run", type: .function, name: "run",
                               filePath: "a.ts", summary: "s", tags: ["t"]))
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "p", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: ""),
            nodes: nodes,
            edges: [GraphEdge(source: "file:a.ts", target: "function:a.ts:run", type: .contains)],
            layers: [], tour: []
        )
        let arrays = GraphArrays.compile(graph)
        let diff = DiffOverlay.compute(changedFiles: ["a.ts"], arrays: arrays, graph: graph)
        // A changed file means everything it contains changed too.
        XCTAssertEqual(diff.changed.count, 2)
    }

    func testUnknownPathsAreHarmless() {
        let (graph, arrays) = makeGraph()
        let diff = DiffOverlay.compute(
            changedFiles: ["never/seen.ts", ".ua/knowledge-graph.json"],
            arrays: arrays, graph: graph
        )
        XCTAssertTrue(diff.isEmpty)
        // The paths are still reported, so the banner can list them even when
        // they correspond to no node.
        XCTAssertEqual(diff.changedFiles.count, 2)
    }

    func testEmptyInputProducesEmptyOverlay() {
        let (graph, arrays) = makeGraph()
        XCTAssertTrue(DiffOverlay.compute(changedFiles: [], arrays: arrays, graph: graph).isEmpty)
    }

    // MARK: - Freshness presentation

    func testFreshnessSeverityOrdersCorrectly() {
        // `unknown` must outrank `fresh`: an unanswerable question is not a
        // clean bill of health.
        XCTAssertLessThan(GitProbe.Freshness.fresh.severity,
                          GitProbe.Freshness.unknown(reason: .notAGitRepository).severity)
        XCTAssertLessThan(GitProbe.Freshness.unknown(reason: .gitCommandTimeout).severity,
                          GitProbe.Freshness.dirty(changedFiles: ["a"]).severity)
        XCTAssertLessThan(
            GitProbe.Freshness.dirty(changedFiles: ["a"]).severity,
            GitProbe.Freshness.stale(relation: .behind, commitsBehind: 1,
                                     commitsAhead: 0, changedFiles: ["a"]).severity
        )
    }

    func testOnlyActionableStatesInviteReanalysis() {
        XCTAssertFalse(GitProbe.Freshness.fresh.isActionable)
        XCTAssertFalse(GitProbe.Freshness.unknown(reason: .notAGitRepository).isActionable)
        XCTAssertTrue(GitProbe.Freshness.dirty(changedFiles: ["a"]).isActionable)
    }

    func testEveryFreshnessStateExplainsItself() {
        let states: [GitProbe.Freshness] = [
            .fresh,
            .dirty(changedFiles: ["a.ts"]),
            .stale(relation: .behind, commitsBehind: 3, commitsAhead: 0, changedFiles: ["a.ts"]),
            .stale(relation: .ahead, commitsBehind: 0, commitsAhead: 2, changedFiles: ["a.ts"]),
            .stale(relation: .diverged, commitsBehind: 1, commitsAhead: 1, changedFiles: ["a.ts"]),
            .unknown(reason: .missingGraphCommit),
            .unknown(reason: .graphCommitUnavailable),
            .unknown(reason: .gitCommandTimeout),
            .unknown(reason: .notAGitRepository),
            .unknown(reason: .gitHeadUnavailable),
        ]
        for state in states {
            XCTAssertFalse(state.headline.isEmpty)
            XCTAssertFalse(state.detail.isEmpty, "\(state) has no explanation")
        }
    }

    func testSingularAndPluralReadCorrectly() {
        XCTAssertTrue(GitProbe.Freshness.dirty(changedFiles: ["a"]).headline
            .contains("1 uncommitted change"))
        XCTAssertTrue(GitProbe.Freshness.dirty(changedFiles: ["a", "b"]).headline
            .contains("2 uncommitted changes"))
        XCTAssertTrue(
            GitProbe.Freshness.stale(relation: .behind, commitsBehind: 1, commitsAhead: 0,
                                     changedFiles: ["a"]).headline.contains("1 commit behind")
        )
    }
}
