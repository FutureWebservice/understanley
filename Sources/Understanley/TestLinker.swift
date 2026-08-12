import Foundation

/// Works out which production files are covered by which tests.
///
/// Ported from the `tested_by` linker in upstream's `merge-batch-graphs.py`.
/// Two passes, for two different problems:
///
/// - **Pass 1** canonicalises `tested_by` edges that already exist. Those come
///   from LLM enrichment, which sees the relationship while reading the *test*
///   file and so naturally emits it backwards. Every edge is normalised to run
///   production → test, and edges that cannot mean anything (test↔test,
///   prod↔prod, an endpoint that is not a file) are dropped.
/// - **Pass 2** adds what convention makes obvious: `foo_test.go` tests
///   `foo.go`, `src/test/java/…/FooTest.java` tests `src/main/java/…/Foo.java`.
///
/// Production files that end up covered gain a `"tested"` tag, which the
/// renderer shows as a small green dot — the cheapest possible answer to "is
/// this code tested?".
enum TestLinker {
    private static let jsTypeScriptExtensions: Set<String> = [
        ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue",
    ]

    /// Directory names that hold tests mirroring a production tree.
    private static let testDirectoryNames: Set<String> = [
        "__tests__", "test", "tests", "spec", "specs",
    ]

    /// Roots a mirrored test tree may correspond to.
    private static let mirrorProductionRoots = ["src", "app", "lib", ""]

    /// Per-extension prefixes and suffixes that mark a test file.
    ///
    /// Ruby and Swift are additions to upstream's table: both have a universal
    /// convention (`*_spec.rb`, `*Tests.swift`) that upstream's list omits, and
    /// leaving them out would mean neither language ever gets coverage edges.
    private static let namePatterns: [String: (prefixes: [String], suffixes: [String])] = [
        ".go": ([], ["_test"]),
        ".py": (["test_"], ["_test"]),
        ".java": ([], ["Test", "Tests", "IT"]),
        ".kt": ([], ["Test", "Tests"]),
        ".scala": ([], ["Spec", "Suite", "Test", "Tests"]),
        ".cs": ([], ["Test", "Tests"]),
        ".c": (["test_"], ["_test"]),
        ".cpp": (["test_"], ["_test"]),
        ".cc": (["test_"], ["_test"]),
        ".rb": ([], ["_spec", "_test"]),
        ".swift": ([], ["Test", "Tests"]),
        ".php": ([], ["Test"]),
        ".rs": ([], ["_test", "_tests"]),
    ]

    /// True when a path names a test file.
    ///
    /// Note that living inside `__tests__/` is deliberately *not* enough: those
    /// directories also hold fixtures, factories and helpers, and treating
    /// those as tests would pair them with unrelated production files.
    static func isTestPath(_ path: String) -> Bool {
        let base = PosixPath.basename(path)
        let ext = PosixPath.fileExtension(base)
        let stem = PosixPath.stem(base)

        if jsTypeScriptExtensions.contains(ext) {
            return stem.hasSuffix(".test") || stem.hasSuffix(".spec")
        }
        guard let patterns = namePatterns[ext] else { return false }
        if patterns.prefixes.contains(where: { stem.hasPrefix($0) }) { return true }
        return patterns.suffixes.contains { stem.hasSuffix($0) }
    }

    /// Production files a test might be exercising, best guess first.
    static func productionCandidates(for testPath: String) -> [String] {
        let dir = PosixPath.directory(of: testPath)
        let base = PosixPath.basename(testPath)
        let ext = PosixPath.fileExtension(base)
        let stem = PosixPath.stem(base)
        var out: [String] = []

        func add(_ path: String) {
            guard !path.isEmpty, !out.contains(path) else { return }
            out.append(path)
        }

        let segments = dir.split(separator: "/").map(String.init)

        if jsTypeScriptExtensions.contains(ext) {
            let baseStem = stem.hasSuffix(".test")
                ? String(stem.dropLast(5))
                : (stem.hasSuffix(".spec") ? String(stem.dropLast(5)) : stem)

            // Same directory, same extension first — then the whole family,
            // because a `.test.ts` commonly covers a `.tsx`.
            add(PosixPath.join(dir, baseStem + ext))
            for candidate in jsTypeScriptExtensions.sorted() {
                add(PosixPath.join(dir, baseStem + candidate))
            }
            // `src/__tests__/foo.test.ts` → `src/foo.ts`
            if let last = segments.last, testDirectoryNames.contains(last) {
                let parent = segments.dropLast().joined(separator: "/")
                add(PosixPath.join(parent, baseStem + ext))
                for candidate in jsTypeScriptExtensions.sorted() {
                    add(PosixPath.join(parent, baseStem + candidate))
                }
            }
            // `tests/utils/foo.test.ts` → `src/utils/foo.ts`
            if let first = segments.first, testDirectoryNames.contains(first) {
                let tail = segments.dropFirst().joined(separator: "/")
                for root in mirrorProductionRoots {
                    add(PosixPath.join(root, tail, baseStem + ext))
                    for candidate in jsTypeScriptExtensions.sorted() {
                        add(PosixPath.join(root, tail, baseStem + candidate))
                    }
                }
            }
            return out
        }

        guard let patterns = namePatterns[ext] else { return [] }
        var baseStem = stem
        for prefix in patterns.prefixes where stem.hasPrefix(prefix) {
            baseStem = String(stem.dropFirst(prefix.count))
            break
        }
        for suffix in patterns.suffixes where baseStem.hasSuffix(suffix) {
            baseStem = String(baseStem.dropLast(suffix.count))
            break
        }
        guard !baseStem.isEmpty else { return [] }

        // Sibling file — the dominant convention for Go, Rust and C.
        add(PosixPath.join(dir, baseStem + ext))

        // Maven/Gradle layout: src/test/<lang> ↔ src/main/<lang>.
        if segments.count >= 3 {
            for index in 0...(segments.count - 3) where segments[index] == "src"
                && segments[index + 1] == "test" {
                var mirrored = segments
                mirrored[index + 1] = "main"
                add(PosixPath.join(mirrored.joined(separator: "/"), baseStem + ext))
            }
        }

        // A trailing test directory: drop it and look in the parent.
        if let last = segments.last, testDirectoryNames.contains(last.lowercased()) {
            let parent = segments.dropLast().joined(separator: "/")
            add(PosixPath.join(parent, baseStem + ext))
            add(PosixPath.join(parent, "src", baseStem + ext))
        }

        // A leading test directory: mirror into the usual source roots.
        if let first = segments.first, testDirectoryNames.contains(first.lowercased()) {
            let tail = segments.dropFirst().joined(separator: "/")
            for root in mirrorProductionRoots {
                add(PosixPath.join(root, tail, baseStem + ext))
            }
        }

        // .NET convention: a sibling `Foo.Tests` project beside `Foo`.
        if let first = segments.first,
           first.hasSuffix(".Tests") || first.hasSuffix(".Test") {
            let stripped = first.hasSuffix(".Tests")
                ? String(first.dropLast(6)) : String(first.dropLast(5))
            let tail = segments.dropFirst().joined(separator: "/")
            add(PosixPath.join(stripped, tail, baseStem + ext))
        }

        // Swift Package Manager: Tests/<Module>Tests ↔ Sources/<Module>.
        if let first = segments.first, first == "Tests" {
            var tail = Array(segments.dropFirst())
            if let module = tail.first, module.hasSuffix("Tests") {
                tail[0] = String(module.dropLast(5))
            }
            add(PosixPath.join("Sources", tail.joined(separator: "/"), baseStem + ext))
        }

        return out
    }

    /// Runs both passes. Returns the number of production/test pairs recorded.
    @discardableResult
    static func link(
        nodes: inout [GraphNode], edges: inout [GraphEdge], edgeKeys: inout Set<String>
    ) -> Int {
        // Only file-level nodes participate; a function cannot be "tested by"
        // in this model.
        var classification: [String: Bool] = [:]  // node id → isTest
        var pathToNodeId: [String: String] = [:]
        for node in nodes where node.type == .file {
            guard let path = node.filePath else { continue }
            classification[node.id] = isTestPath(path)
            pathToNodeId[path] = node.id
        }

        // ── Pass 1: canonicalise what already exists ──
        var covered = Set<String>()          // "prod\u{1}test"
        var pairedTestIds = Set<String>()
        var survivors: [GraphEdge] = []
        survivors.reserveCapacity(edges.count)

        for edge in edges {
            guard edge.type == .tested_by else {
                survivors.append(edge)
                continue
            }
            guard let sourceIsTest = classification[edge.source],
                  let targetIsTest = classification[edge.target] else {
                // An endpoint that is not a file node — nothing this edge could
                // mean, so it goes.
                continue
            }

            let prod: String
            let test: String
            if !sourceIsTest, targetIsTest {
                prod = edge.source
                test = edge.target
            } else if sourceIsTest, !targetIsTest {
                prod = edge.target
                test = edge.source
            } else {
                // test↔test or prod↔prod: semantically broken either way.
                continue
            }

            let key = "\(prod)\u{1}\(test)"
            guard covered.insert(key).inserted else { continue }
            pairedTestIds.insert(test)

            var canonical = edge
            if canonical.source != prod {
                canonical.source = prod
                canonical.target = test
                canonical.direction = .forward
                canonical.description = canonical.description.map { "\($0) [direction corrected]" }
                    ?? "Direction corrected (was test → production)"
            }
            survivors.append(canonical)
            edgeKeys.insert(canonical.dedupeKey)
        }
        edges = survivors

        // ── Pass 2: supplement by path convention ──
        var added = 0
        for node in nodes where node.type == .file {
            guard let path = node.filePath, isTestPath(path) else { continue }
            guard !pairedTestIds.contains(node.id) else { continue }

            for candidate in productionCandidates(for: path) {
                guard let prodId = pathToNodeId[candidate], prodId != node.id else { continue }
                guard classification[prodId] == false else { continue }
                let key = "\(prodId)\u{1}\(node.id)"
                guard !covered.contains(key) else { break }

                covered.insert(key)
                let edge = GraphEdge(
                    source: prodId, target: node.id, type: .tested_by,
                    description: "Path-based pairing (deterministic)"
                )
                if edgeKeys.insert(edge.dedupeKey).inserted {
                    edges.append(edge)
                    added += 1
                }
                // One production file per test — the first convention that
                // matches is the intended one.
                break
            }
        }

        // ── Tag covered production nodes ──
        let coveredProductionIds = Set(covered.map { String($0.split(separator: "\u{1}")[0]) })
        for index in nodes.indices where coveredProductionIds.contains(nodes[index].id) {
            if !nodes[index].tags.contains("tested") {
                nodes[index].tags.append("tested")
            }
        }

        return added
    }
}
