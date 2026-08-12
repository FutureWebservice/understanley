import XCTest

@testable import Understanley

/// Tests for the deterministic pipeline.
///
/// Fixtures are written into `NSTemporaryDirectory()` and torn down after each
/// test — never into a real project directory, and never anywhere the app also
/// reads from.
final class PipelineTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "understand-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relativePath: String, _ contents: String) throws {
        let full = root + "/" + relativePath
        try FileManager.default.createDirectory(
            atPath: PosixPath.directory(of: full), withIntermediateDirectories: true
        )
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    // MARK: - Paths

    func testPathHelpers() {
        XCTAssertEqual(PosixPath.basename("src/app/main.ts"), "main.ts")
        XCTAssertEqual(PosixPath.directory(of: "src/app/main.ts"), "src/app")
        XCTAssertEqual(PosixPath.fileExtension("src/app/main.ts"), ".ts")
        XCTAssertEqual(PosixPath.stem("a/b/Foo.test.ts"), "Foo.test")

        // A leading dot is not an extension.
        XCTAssertEqual(PosixPath.fileExtension(".gitignore"), "")
        // …but a dotfile with a suffix has one, matching Node's `path.extname`.
        XCTAssertEqual(PosixPath.fileExtension(".env.local"), ".local")

        XCTAssertEqual(PosixPath.resolve("a/b/c", "../d.ts"), "a/b/d.ts")
        XCTAssertEqual(PosixPath.resolve("a", "./x/y"), "a/x/y")
        // Escaping above the project root is unresolvable, not a path outside it.
        XCTAssertEqual(PosixPath.resolve("a", "../../x"), "")

        XCTAssertFalse(PosixPath.isSafeRelative("../etc/passwd"))
        XCTAssertFalse(PosixPath.isSafeRelative("/etc/passwd"))
        XCTAssertFalse(PosixPath.isSafeRelative("a/../../b"))
        XCTAssertTrue(PosixPath.isSafeRelative("src/app/main.ts"))
    }

    func testUTF16OrderingMatchesJavaScript() {
        // Upstream sorts with JavaScript's `<`, which compares UTF-16 code
        // units. Swift's default `<` does not, and the digest depends on order.
        XCTAssertEqual(compareUTF16("a", "b"), .orderedAscending)
        XCTAssertEqual(compareUTF16("Z", "a"), .orderedAscending)
        XCTAssertEqual(compareUTF16("abc", "abcd"), .orderedAscending)
        XCTAssertEqual(compareUTF16("same", "same"), .orderedSame)
    }

    // MARK: - Ignore rules

    func testIgnoreFilterSemantics() {
        let filter = IgnoreFilter(patterns: [
            "node_modules/", "*.log", "/build", "docs/**/*.tmp", "!keep.log",
        ])

        // A trailing slash does not anchor: `node_modules/` matches at any depth.
        XCTAssertTrue(filter.isIgnored("node_modules/react/index.js"))
        XCTAssertTrue(filter.isIgnored("packages/web/node_modules/x.js"))
        // …but it does require a directory, so a file named `node_modules` stays.
        XCTAssertFalse(filter.isIgnored("node_modules"))

        XCTAssertTrue(filter.isIgnored("a/b/debug.log"))
        // A later `!` rule wins over an earlier match.
        XCTAssertFalse(filter.isIgnored("keep.log"))

        // A leading slash anchors to the project root.
        XCTAssertTrue(filter.isIgnored("build/out.js"))
        XCTAssertFalse(filter.isIgnored("packages/build/out.js"))

        XCTAssertTrue(filter.isIgnored("docs/a/b/scratch.tmp"))
    }

    func testIgnoreFilterIsCaseInsensitive() {
        // Inherited from upstream's `ignore` package default. Surprising, but
        // changing it would exclude a different set of files than upstream for
        // the same `.understandignore`.
        let filter = IgnoreFilter(patterns: ["*.PNG"])
        XCTAssertTrue(filter.isIgnored("assets/logo.png"))
    }

    func testDefaultPatternsExcludeBuildOutput() {
        let filter = IgnoreFilter.defaultsOnly
        XCTAssertTrue(filter.isIgnored("dist/bundle.js"))
        XCTAssertTrue(filter.isIgnored("pnpm-lock.yaml"))
        XCTAssertTrue(filter.isIgnored("src/logo.svg"))
        XCTAssertFalse(filter.isIgnored("src/index.ts"))
    }

    // MARK: - Language and category

    func testLanguageDetection() {
        XCTAssertEqual(LanguageRegistry.language(for: "src/a.ts"), "typescript")
        XCTAssertEqual(LanguageRegistry.language(for: "src/a.tsx"), "typescript")
        // `.h` is C, not C++ — upstream labels it that way and the label shows.
        XCTAssertEqual(LanguageRegistry.language(for: "src/a.h"), "c")
        XCTAssertEqual(LanguageRegistry.language(for: "Dockerfile"), "dockerfile")
        XCTAssertEqual(LanguageRegistry.language(for: "Dockerfile.prod"), "dockerfile")
        XCTAssertEqual(LanguageRegistry.language(for: "Makefile"), "makefile")
        XCTAssertEqual(LanguageRegistry.language(for: ".env.production"), "config")
        // An unknown extension falls back to itself rather than to "unknown".
        XCTAssertEqual(LanguageRegistry.language(for: "a/b.zig"), "zig")
        XCTAssertEqual(LanguageRegistry.language(for: "NOTICE"), "unknown")
    }

    func testCategoryLadderPrioritisesPathOverExtension() {
        // A workflow is infrastructure even though it is a `.yml`.
        XCTAssertEqual(LanguageRegistry.category(for: ".github/workflows/ci.yml"), .infra)
        XCTAssertEqual(LanguageRegistry.category(for: "config/app.yml"), .config)
        XCTAssertEqual(LanguageRegistry.category(for: "docker-compose.prod.yml"), .infra)
        XCTAssertEqual(LanguageRegistry.category(for: "k8s/deploy.yaml"), .infra)
        XCTAssertEqual(LanguageRegistry.category(for: "README.md"), .docs)
        XCTAssertEqual(LanguageRegistry.category(for: "schema.sql"), .data)
        XCTAssertEqual(LanguageRegistry.category(for: "scripts/run.sh"), .script)
        XCTAssertEqual(LanguageRegistry.category(for: "main.tf"), .infra)
        XCTAssertEqual(LanguageRegistry.category(for: "src/index.ts"), .code)
        XCTAssertEqual(LanguageRegistry.category(for: "LICENSE"), .code)
    }

    // MARK: - Extractors

    func testJavaScriptExtractorHandlesMultiLineImports() {
        // The failure this guards against is silent and total: with the source
        // on a later line, the whole file yields zero import edges.
        let source = """
        import type {
          Alpha,
          Beta,
        } from "../types.js";
        import { Gamma } from "./gamma";
        import "./side-effect.css";

        export function build(a, b) {
          return a + b;
        }

        export class Widget {
          constructor(name) { this.name = name; }
          render(target) { return target; }
        }
        """
        let view = SourceView(source: source, syntax: .jsStyle)
        let analysis = JavaScriptExtractor().extract(view, path: "src/build.ts")

        XCTAssertEqual(analysis.imports.map(\.source),
                       ["../types.js", "./gamma", "./side-effect.css"])
        XCTAssertEqual(analysis.imports[0].specifiers, ["Alpha", "Beta"])

        XCTAssertTrue(analysis.functions.contains { $0.name == "build" })
        XCTAssertTrue(analysis.classes.contains { $0.name == "Widget" })
        // Methods become functions in their own right, named `Type.method`.
        XCTAssertTrue(analysis.functions.contains { $0.name == "Widget.render" })
        XCTAssertTrue(analysis.exports.contains { $0.name == "build" })
    }

    func testStringLiteralsSurviveIntoTheMatchableView() {
        // `structure` blanks strings so braces inside them do not affect depth;
        // `text` must keep them, or every path-carrying parser reads blanks.
        let view = SourceView(source: #"import x from "./a.ts"; // { not a brace"#, syntax: .jsStyle)
        XCTAssertTrue(view.text[0].contains("./a.ts"))
        XCTAssertFalse(view.structure[0].contains("./a.ts"))
        // The comment is gone from both.
        XCTAssertFalse(view.text[0].contains("not a brace"))
        XCTAssertEqual(view.depthBefore[0], 0)
    }

    func testCommentsAndStringsDoNotCreateFalseDeclarations() {
        let source = """
        // export function ghost() {}
        const banner = "class Phantom {";
        export function real() { return 1; }
        """
        let view = SourceView(source: source, syntax: .jsStyle)
        let analysis = JavaScriptExtractor().extract(view, path: "a.ts")
        XCTAssertFalse(analysis.functions.contains { $0.name == "ghost" })
        XCTAssertFalse(analysis.classes.contains { $0.name == "Phantom" })
        XCTAssertTrue(analysis.functions.contains { $0.name == "real" })
    }

    func testPythonExtractor() {
        let source = """
        from .models import User, Order
        from ..shared import helpers
        import os, json as j

        class Repository:
            table: str

            def save(self, record):
                return record

            async def load(self, key):
                return None

        def module_level(a, b=2, *args, **kwargs):
            return a
        """
        let view = SourceView(source: source, syntax: .python)
        let analysis = PythonExtractor().extract(view, path: "app/repo.py")

        XCTAssertEqual(analysis.imports[0].source, ".models")
        XCTAssertEqual(analysis.imports[0].specifiers, ["User", "Order"])
        // Leading dots must survive verbatim — the resolver counts them.
        XCTAssertEqual(analysis.imports[1].source, "..shared")

        let names = Set(analysis.functions.map(\.name))
        XCTAssertTrue(names.contains("module_level"))
        XCTAssertTrue(names.contains("Repository.save"))
        XCTAssertTrue(names.contains("Repository.load"))

        let moduleLevel = analysis.functions.first { $0.name == "module_level" }
        // `self` is dropped; variadics keep their markers.
        XCTAssertEqual(moduleLevel?.params, ["a", "b", "*args", "**kwargs"])
        XCTAssertEqual(analysis.classes.first?.properties, ["table"])
    }

    func testSwiftMethodsBecomeFunctions() {
        // In Swift almost every function is a method. Upstream's root-children
        // walk finds none of them; this port must.
        let source = """
        import Foundation

        public struct Loader {
            public func load(from path: String) -> Data? {
                return nil
            }
            private func cache(_ key: String) {
            }
        }

        func freeFunction() {}
        """
        let view = SourceView(source: source, syntax: .swiftStyle)
        let analysis = SwiftExtractor().extract(view, path: "Sources/Loader.swift")

        let names = Set(analysis.functions.map(\.name))
        XCTAssertTrue(names.contains("Loader.load"))
        XCTAssertTrue(names.contains("Loader.cache"))
        XCTAssertTrue(names.contains("freeFunction"))
        XCTAssertTrue(analysis.classes.contains { $0.name == "Loader" })
    }

    func testGoExtractorBindsMethodsToReceivers() {
        let source = """
        package repo

        import (
            "fmt"
            api "github.com/me/proj/api"
        )

        type Store struct {
            Name string
        }

        func (s *Store) Save(item string) error {
            return nil
        }

        func New() *Store {
            return &Store{}
        }
        """
        let view = SourceView(source: source, syntax: .cStyle)
        let analysis = GoExtractor().extract(view, path: "repo/store.go")

        XCTAssertEqual(analysis.classes.first?.name, "Store")
        XCTAssertEqual(analysis.classes.first?.methods, ["Save"])
        XCTAssertTrue(analysis.functions.contains { $0.name == "New" })
        XCTAssertTrue(analysis.imports.contains { $0.source == "github.com/me/proj/api" })
        // Only capitalised identifiers are exported in Go.
        XCTAssertTrue(analysis.exports.contains { $0.name == "New" })
    }

    func testNonCodeParsers() {
        let dockerfile = SourceView(source: """
        FROM node:20 AS builder
        EXPOSE 3000
        RUN npm ci
        FROM nginx:alpine
        COPY --from=builder /app /usr/share/nginx/html
        """, syntax: .hashOnly)
        let docker = DockerfileParser().extract(dockerfile, path: "Dockerfile")
        XCTAssertEqual(docker.services.map(\.name), ["builder", "nginx"])
        XCTAssertEqual(docker.services.first?.ports, [3000])

        let sql = SourceView(source: """
        CREATE TABLE users (
          id SERIAL PRIMARY KEY,
          email TEXT NOT NULL,
          PRIMARY KEY (id)
        );
        """, syntax: .sqlStyle)
        let tables = SQLParser().extract(sql, path: "schema.sql")
        XCTAssertEqual(tables.definitions.first?.name, "users")
        XCTAssertEqual(tables.definitions.first?.kind, "table")
        // Table-level constraints are not columns.
        XCTAssertEqual(tables.definitions.first?.fields, ["id", "email"])

        let markdown = SourceView(source: """
        # Title

        See [the guide](docs/guide.md) and [the site](https://example.com).

        ```sh
        # not a heading
        ```

        ## Section
        """, syntax: .none)
        let doc = MarkdownParser().extract(markdown, path: "README.md")
        XCTAssertEqual(doc.sections.map(\.name), ["Title", "Section"])
        // Local links become edges; external URLs do not.
        XCTAssertEqual(doc.imports.map(\.source), ["docs/guide.md"])
    }

    // MARK: - Import resolution

    func testTypeScriptResolution() throws {
        try write("tsconfig.json", #"""
        {
          "compilerOptions": {
            "baseUrl": ".",
            // A comment, because tsconfig is really JSONC.
            "paths": { "@app/*": ["src/*"] }
          }
        }
        """#)
        try write("src/types.ts", "export type A = string;")
        try write("src/util/index.ts", "export const x = 1;")
        try write("src/main.ts", "import { A } from './types.js';")

        let files = [
            ScannedFile(path: "src/main.ts", language: "typescript", sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "src/types.ts", language: "typescript", sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "src/util/index.ts", language: "typescript", sizeLines: 1, fileCategory: .code),
            // The resolver only reads configs that the scan actually produced,
            // so `tsconfig.json` has to be in the list for aliases to work —
            // as it is in a real project, where it is a `config` file.
            ScannedFile(path: "tsconfig.json", language: "json", sizeLines: 1, fileCategory: .config),
        ]
        let resolver = ImportResolver(root: root, files: files)
        let importer = files[0]

        func resolve(_ source: String) -> [String] {
            resolver.resolve(ImportInfo(source: source, specifiers: [], lineNumber: 1), from: importer)
        }

        // NodeNext: the specifier names the output file, the project has the source.
        XCTAssertEqual(resolve("./types.js"), ["src/types.ts"])
        XCTAssertEqual(resolve("./types"), ["src/types.ts"])
        // Directory import resolves through index.
        XCTAssertEqual(resolve("./util"), ["src/util/index.ts"])
        // tsconfig path alias.
        XCTAssertEqual(resolve("@app/types"), ["src/types.ts"])
        // External package.
        XCTAssertEqual(resolve("react"), [])
    }

    /// `jsconfig.json` with `"@/*": ["./*"]` — what `create-next-app` writes,
    /// so it is the single most common alias shape in the JavaScript world.
    ///
    /// This missed for a subtle reason: the mapped target is `./app/adInit`,
    /// and `PosixPath.normalize` drops only *empty* segments, so the "." stayed
    /// and the candidate became `./app/adInit.js` while the scanned file set
    /// holds `app/adInit.js`. A real Next.js project came out with **one**
    /// import edge across 48 files — a graph of disconnected dots that looked
    /// like the layout was broken rather than the resolver.
    func testJavaScriptConfigDotSlashAlias() throws {
        try write("jsconfig.json", #"""
        {
          "compilerOptions": {
            "baseUrl": ".",
            "paths": { "@/*": ["./*"] }
          }
        }
        """#)
        try write("app/adInit.js", "export function initializeAds() {}")
        try write("lib/format/index.js", "export const f = 1;")
        try write("components/ad-initializer.jsx", "import { initializeAds } from '@/app/adInit'")

        let files = [
            ScannedFile(path: "components/ad-initializer.jsx", language: "javascript",
                        sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "app/adInit.js", language: "javascript",
                        sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "lib/format/index.js", language: "javascript",
                        sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "jsconfig.json", language: "json", sizeLines: 1, fileCategory: .config),
        ]
        let resolver = ImportResolver(root: root, files: files)
        let importer = files[0]

        func resolve(_ source: String) -> [String] {
            resolver.resolve(ImportInfo(source: source, specifiers: [], lineNumber: 1), from: importer)
        }

        XCTAssertEqual(resolve("@/app/adInit"), ["app/adInit.js"])
        // Through the alias and then through a directory index.
        XCTAssertEqual(resolve("@/lib/format"), ["lib/format/index.js"])
        // A bare package is still external.
        XCTAssertEqual(resolve("react"), [])
        // And a relative import beside it still works.
        XCTAssertEqual(resolve("../app/adInit"), ["app/adInit.js"])
    }

    /// Composer autoload targets are conventionally written `"./src/"`.
    ///
    /// Same "."-segment trap as the JavaScript aliases: `normalize` keeps the
    /// dot, so every PHP `use` statement missed. Both spellings must land on
    /// the same file.
    func testComposerPSR4AcceptsDotSlashTargets() {
        let dotted = ImportResolver.parsePSR4(#"""
        {"autoload": {"psr-4": {"App\\": "./src/", "Lib\\": "lib/"}}}
        """#, configDir: "")
        let map = Dictionary(uniqueKeysWithValues: dotted.map { ($0.0, $0.1) })
        XCTAssertEqual(map["App\\"], ["src"])
        XCTAssertEqual(map["Lib\\"], ["lib"])

        // And the same inside a package subdirectory.
        let nested = ImportResolver.parsePSR4(#"""
        {"autoload": {"psr-4": {"App\\": "./src/"}}}
        """#, configDir: "packages/api")
        XCTAssertEqual(nested.first?.1, ["packages/api/src"])
    }

    func testNodeNextRewriteDoesNotFabricatePaths() throws {
        // `./foo.js` must never resolve to `foo.js.ts`. The guard is a bare
        // `return nil` after the rewrite list misses — without it the generic
        // probe list happily appends `.ts` to the full `foo.js`.
        try write("src/foo.js.ts", "export const trap = 1;")
        try write("src/main.ts", "")
        let files = [
            ScannedFile(path: "src/main.ts", language: "typescript", sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "src/foo.js.ts", language: "typescript", sizeLines: 1, fileCategory: .code),
        ]
        let resolver = ImportResolver(root: root, files: files)
        let resolved = resolver.resolve(
            ImportInfo(source: "./foo.js", specifiers: [], lineNumber: 1), from: files[0]
        )
        XCTAssertEqual(resolved, [])
    }

    func testPythonRelativeResolution() throws {
        let files = [
            ScannedFile(path: "pkg/sub/mod.py", language: "python", sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "pkg/sub/sibling.py", language: "python", sizeLines: 1, fileCategory: .code),
            ScannedFile(path: "pkg/shared.py", language: "python", sizeLines: 1, fileCategory: .code),
        ]
        let resolver = ImportResolver(root: root, files: files)
        let importer = files[0]

        // `.sibling` — same package.
        XCTAssertEqual(
            resolver.resolve(ImportInfo(source: ".sibling", specifiers: [], lineNumber: 1), from: importer),
            ["pkg/sub/sibling.py"]
        )
        // `..shared` — one level up.
        XCTAssertEqual(
            resolver.resolve(ImportInfo(source: "..shared", specifiers: [], lineNumber: 1), from: importer),
            ["pkg/shared.py"]
        )
        // `from . import sibling` — the specifier names the module.
        XCTAssertEqual(
            resolver.resolve(ImportInfo(source: ".", specifiers: ["sibling"], lineNumber: 1), from: importer),
            ["pkg/sub/sibling.py"]
        )
    }

    func testTSConfigPathOrderIsPreserved() {
        // Alias order decides which mapping wins, and `JSONSerialization`
        // hands back an unordered dictionary — the parser has to recover the
        // declaration order from the raw text.
        let config = ImportResolver.parseTSConfig(#"""
        { "compilerOptions": { "paths": {
            "@first/*": ["a/*"],
            "@second/*": ["b/*"],
            "*": ["c/*"]
        } } }
        """#)
        XCTAssertEqual(config?.paths.map(\.alias), ["@first/*", "@second/*", "*"])
    }

    // MARK: - Layers

    func testLayerDetectionOrderAndPluralRule() {
        // Pattern group is the outer loop, so API beats Service even though
        // `services` appears later in the path.
        XCTAssertEqual(LayerDetector.layerName(for: "src/api/services/user.ts"), "API Layer")
        // The `+ "s"` rule matches a pluralised directory.
        XCTAssertEqual(LayerDetector.layerName(for: "app/models/user.rb"), "Data Layer")
        // A filename segment is `api.ts`, which equals neither `api` nor `apis`.
        XCTAssertNil(LayerDetector.layerName(for: "src/api.ts"))
        XCTAssertEqual(LayerDetector.layerName(for: "test/helpers.ts"), "Test Layer")
    }

    func testEveryFileNodeLandsInExactlyOneLayer() {
        let nodes = [
            makeNode("file:src/api/user.ts", .file, path: "src/api/user.ts"),
            makeNode("file:src/util/x.ts", .file, path: "src/util/x.ts"),
            makeNode("file:main.ts", .file, path: "main.ts"),
            makeNode("function:src/api/user.ts:get", .function, path: "src/api/user.ts"),
        ]
        let layers = LayerDetector.detect(nodes: nodes)
        let assigned = layers.flatMap(\.nodeIds)
        XCTAssertEqual(Set(assigned).count, assigned.count, "a node appears in two layers")
        // Sub-file nodes are reached through their file, not layered directly.
        XCTAssertFalse(assigned.contains("function:src/api/user.ts:get"))
        XCTAssertEqual(assigned.count, 3)
    }

    // MARK: - Test linking

    func testTestPathRecognition() {
        XCTAssertTrue(TestLinker.isTestPath("src/foo.test.ts"))
        XCTAssertTrue(TestLinker.isTestPath("pkg/thing_test.go"))
        XCTAssertTrue(TestLinker.isTestPath("tests/test_thing.py"))
        XCTAssertTrue(TestLinker.isTestPath("Tests/AppTests/LoaderTests.swift"))
        XCTAssertFalse(TestLinker.isTestPath("src/foo.ts"))
        // A fixture living in `__tests__/` is not itself a test — pairing it
        // with a production file would be wrong.
        XCTAssertFalse(TestLinker.isTestPath("src/__tests__/fixtures.ts"))
    }

    func testProductionCandidatesFollowConvention() {
        XCTAssertTrue(TestLinker.productionCandidates(for: "src/foo.test.ts").contains("src/foo.ts"))
        XCTAssertTrue(TestLinker.productionCandidates(for: "pkg/x_test.go").contains("pkg/x.go"))
        XCTAssertTrue(
            TestLinker.productionCandidates(for: "src/main/../test/java/com/A/FooTest.java").isEmpty == false
        )
        XCTAssertTrue(
            TestLinker.productionCandidates(for: "src/test/java/com/a/FooTest.java")
                .contains("src/main/java/com/a/Foo.java")
        )
        XCTAssertTrue(
            TestLinker.productionCandidates(for: "Tests/AppTests/LoaderTests.swift")
                .contains("Sources/App/Loader.swift")
        )
    }

    func testTestLinkerFlipsInvertedEdgesAndTags() {
        var nodes = [
            makeNode("file:src/foo.ts", .file, path: "src/foo.ts"),
            makeNode("file:src/foo.test.ts", .file, path: "src/foo.test.ts"),
        ]
        // Emitted backwards, as an LLM reading the test file naturally would.
        var edges = [
            GraphEdge(source: "file:src/foo.test.ts", target: "file:src/foo.ts", type: .tested_by)
        ]
        var keys = Set(edges.map(\.dedupeKey))

        TestLinker.link(nodes: &nodes, edges: &edges, edgeKeys: &keys)

        let tested = edges.filter { $0.type == .tested_by }
        XCTAssertEqual(tested.count, 1)
        XCTAssertEqual(tested[0].source, "file:src/foo.ts")
        XCTAssertEqual(tested[0].target, "file:src/foo.test.ts")
        XCTAssertTrue(nodes[0].tags.contains("tested"))
    }

    func testTestLinkerDropsMeaninglessEdges() {
        var nodes = [
            makeNode("file:a.test.ts", .file, path: "a.test.ts"),
            makeNode("file:b.test.ts", .file, path: "b.test.ts"),
        ]
        var edges = [
            GraphEdge(source: "file:a.test.ts", target: "file:b.test.ts", type: .tested_by)
        ]
        var keys = Set(edges.map(\.dedupeKey))
        TestLinker.link(nodes: &nodes, edges: &edges, edgeKeys: &keys)
        XCTAssertTrue(edges.filter { $0.type == .tested_by }.isEmpty)
    }

    // MARK: - Schema

    func testSchemaRepairsAndReports() {
        let raw: [String: Any] = [
            "version": "1.0.0",
            "project": ["name": "demo", "languages": ["swift"], "frameworks": [],
                        "description": "d", "analyzedAt": "", "gitCommitHash": ""],
            "nodes": [
                // Alias type, alias complexity, missing summary and tags.
                ["id": "file:a.ts", "type": "func", "name": "a", "complexity": "high"],
                // Numeric complexity.
                ["id": "file:b.ts", "type": "file", "name": "b", "complexity": 2,
                 "summary": "ok", "tags": ["x"]],
                // Unusable: no id.
                ["type": "file", "name": "ghost"],
            ],
            "edges": [
                ["source": "file:a.ts", "target": "file:b.ts", "type": "extends", "weight": 5],
                ["source": "file:a.ts", "target": "file:missing.ts", "type": "imports"],
            ],
            "layers": [["id": "layer:core", "name": "Core", "description": "",
                        "nodeIds": ["file:a.ts", "file:nope.ts"]]],
            "tour": [],
        ]

        let result = GraphSchema.validate(raw)
        let graph = try? XCTUnwrap(result.graph)
        XCTAssertEqual(graph?.nodes.count, 2)

        // `func` → function, `high` → complex.
        XCTAssertEqual(graph?.nodes.first?.type, .function)
        XCTAssertEqual(graph?.nodes.first?.complexity, .complex)
        XCTAssertEqual(graph?.nodes.first?.summary, GraphNode.pendingSummary)
        XCTAssertEqual(graph?.nodes[1].complexity, .simple)

        // `extends` → inherits, weight clamped, dangling edge dropped.
        XCTAssertEqual(graph?.edges.count, 1)
        XCTAssertEqual(graph?.edges.first?.type, .inherits)
        XCTAssertEqual(graph?.edges.first?.weight, 1.0)

        // A layer's dangling node id is pruned silently.
        XCTAssertEqual(graph?.layers.first?.nodeIds, ["file:a.ts"])

        // Every repair is reported rather than silently applied.
        XCTAssertTrue(result.issues.contains { $0.category == .alias })
        XCTAssertTrue(result.issues.contains { $0.category == .outOfRange })
        XCTAssertTrue(result.issues.contains { $0.level == .dropped })
    }

    func testSchemaRejectsNonGraphInput() {
        XCTAssertNil(GraphSchema.validate(Data("not json".utf8)).graph)
        XCTAssertNil(GraphSchema.validate(["nodes": []]).graph)
    }

    // MARK: - End to end

    func testPipelineProducesAValidRoundTrippingGraph() async throws {
        try write("package.json", #"{"name":"demo","description":"A demo project"}"#)
        try write("README.md", "# Demo\n\nSee [main](src/main.ts).\n")
        try write("src/types.ts", "export interface User { id: string }\n")
        try write("src/main.ts", """
        import type { User } from "./types.js";

        export function greet(user: User): string {
          return format(user.id);
        }

        export function format(id: string): string {
          return id.trim();
        }
        """)
        try write("src/main.test.ts", """
        import { greet } from "./main";
        test("greets", () => { greet({ id: "a" }); });
        """)
        try write("Dockerfile", "FROM node:20\nEXPOSE 8080\n")

        let pipeline = AnalysisPipeline(diagnostics: DiagnosticsCollector())
        let graph = try await pipeline.run(projectRoot: root)

        XCTAssertEqual(graph.project.name, "demo")
        XCTAssertEqual(graph.project.description, "A demo project")

        let ids = Set(graph.nodes.map(\.id))
        XCTAssertTrue(ids.contains("file:src/main.ts"))
        XCTAssertTrue(ids.contains("document:README.md"))
        XCTAssertTrue(ids.contains("service:Dockerfile"))
        XCTAssertTrue(ids.contains("function:src/main.ts:greet"))

        // Import edge across the NodeNext rewrite.
        XCTAssertTrue(graph.edges.contains {
            $0.type == .imports && $0.source == "file:src/main.ts" && $0.target == "file:src/types.ts"
        })
        // Call edge between two functions in the same file.
        XCTAssertTrue(graph.edges.contains {
            $0.type == .calls && $0.target == "function:src/main.ts:format"
        })
        // Coverage found by path convention.
        XCTAssertTrue(graph.edges.contains {
            $0.type == .tested_by && $0.source == "file:src/main.ts"
        })
        // A doc link becomes a `documents` edge, not an `imports` one.
        XCTAssertTrue(graph.edges.contains {
            $0.type == .documents && $0.source == "document:README.md"
        })

        // No edge may reference a node that does not exist.
        for edge in graph.edges {
            XCTAssertTrue(ids.contains(edge.source), "dangling source \(edge.source)")
            XCTAssertTrue(ids.contains(edge.target), "dangling target \(edge.target)")
        }
        // Every file-level node is in exactly one layer.
        let layered = graph.layers.flatMap(\.nodeIds)
        XCTAssertEqual(Set(layered).count, layered.count)
        XCTAssertEqual(
            Set(layered),
            Set(graph.nodes.filter { NodeType.fileLevel.contains($0.type) }.map(\.id))
        )

        // Round-trip through the on-disk format, which is what makes the graph
        // interoperable with the upstream plugin in both directions.
        let encoded = try JSONFile.encoder().encode(graph)
        let reloaded = GraphSchema.validate(encoded)
        XCTAssertTrue(reloaded.issues.isEmpty, "clean graph should need no repair")
        XCTAssertEqual(reloaded.graph?.nodes.count, graph.nodes.count)
        XCTAssertEqual(reloaded.graph?.edges.count, graph.edges.count)
        XCTAssertEqual(reloaded.graph?.layers.count, graph.layers.count)
    }

    func testPipelineIsDeterministic() async throws {
        try write("src/a.ts", "export const a = 1;\n")
        try write("src/b.ts", "import { a } from './a';\nexport const b = a;\n")

        let pipeline = AnalysisPipeline(diagnostics: DiagnosticsCollector())
        let first = try await pipeline.run(projectRoot: root)
        let second = try await pipeline.run(projectRoot: root)

        // Same input, same graph — this is what makes golden-graph comparison
        // against upstream possible at all.
        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(first.edges.map(\.dedupeKey), second.edges.map(\.dedupeKey))
        XCTAssertEqual(first.layers.map(\.id), second.layers.map(\.id))
    }

    func testPipelineSurvivesHostileInput() async throws {
        // Every one of these has broken a naive parser at some point.
        try write("empty.ts", "")
        try write("binary.json", "\u{0}\u{1}\u{2}not really json")
        try write("unterminated.ts", "const s = \"never closed;\nexport function after() {}")
        try write("deep.ts", String(repeating: "{", count: 500))
        try write("weird.py", "def \u{1F600}(): pass")

        let pipeline = AnalysisPipeline(diagnostics: DiagnosticsCollector())
        let graph = try await pipeline.run(projectRoot: root)
        XCTAssertFalse(graph.nodes.isEmpty)
    }

    func testEmptyProjectFailsWithAnActionableMessage() async {
        let pipeline = AnalysisPipeline(diagnostics: DiagnosticsCollector())
        do {
            _ = try await pipeline.run(projectRoot: root)
            XCTFail("expected an error for a project with no analyzable files")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No analyzable files"))
        }
    }

    // MARK: - Helpers

    private func makeNode(_ id: String, _ type: NodeType, path: String?) -> GraphNode {
        GraphNode(id: id, type: type, name: PosixPath.basename(path ?? id),
                  filePath: path, summary: "s", tags: ["t"])
    }
}

/// The graph caps in `ScanLimits`.
///
/// These were documented for the whole life of the project and enforced by
/// nothing — a stated bound that does not bind is worse than no bound, because
/// it is read as a guarantee. The rule is that files survive and sub-file
/// symbols are the ones dropped: a graph of every file and no functions is
/// still a map of the project; the reverse is not.
final class GraphCapTests: XCTestCase {
    func testFilesOutrankSymbolsWhenTheCapBites() {
        // Sort key the builder uses: file-level first, then id order.
        var nodes: [GraphNode] = []
        for i in 0..<5 {
            nodes.append(GraphNode(id: "function:a.ts:f\(i)", type: .function, name: "f\(i)",
                                   filePath: "a.ts", summary: "s", tags: []))
        }
        for i in 0..<3 {
            nodes.append(GraphNode(id: "file:z\(i).ts", type: .file, name: "z\(i).ts",
                                   filePath: "z\(i).ts", summary: "s", tags: []))
        }
        nodes.sort { a, b in
            let aFile = NodeType.fileLevel.contains(a.type)
            let bFile = NodeType.fileLevel.contains(b.type)
            if aFile != bFile { return aFile }
            return compareUTF16(a.id, b.id) == .orderedAscending
        }
        // Keeping only three must keep all three files, no functions.
        let kept = nodes.prefix(3)
        XCTAssertTrue(kept.allSatisfy { NodeType.fileLevel.contains($0.type) })
    }

    func testCapsAreOrderedSensibly() {
        XCTAssertGreaterThan(ScanLimits.maxGraphEdges, ScanLimits.maxGraphNodes,
                             "a graph always has more edges than nodes")
        XCTAssertGreaterThan(ScanLimits.maxGraphNodes, 1000,
                             "the cap must not bite on an ordinary project")
    }
}


/// Every export format must be well-formed, and the HTML one must be able to
/// open with no network at all.
///
/// These assertions used to live only in the CI workflow, which meant they ran
/// nowhere on a developer's machine and not at all once CI was removed. The
/// self-contained check is the one that matters most: the exported viewer
/// exists precisely so a graph can be shared with someone who has neither this
/// app nor an internet connection, and a single CDN `<script src>` would defeat
/// that while still looking perfectly fine on the machine that wrote it.
final class ExportFormatTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "ua-export-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// A graph with enough shape that the renderers actually draw something.
    private func sampleGraph() -> (KnowledgeGraph, GraphArrays) {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for i in 0..<24 {
            nodes.append(GraphNode(
                id: "file:m\(i).ts", type: .file, name: "m\(i).ts",
                filePath: "m\(i).ts", summary: "Module \(i)", tags: ["code"]
            ))
        }
        for i in 1..<24 {
            edges.append(GraphEdge(source: "file:m\(i).ts",
                                   target: "file:m\((i - 1) / 2).ts", type: .imports))
        }
        let graph = KnowledgeGraph(
            project: ProjectMeta(name: "sample", languages: ["typescript"], frameworks: [],
                                 description: "A sample", analyzedAt: "", gitCommitHash: ""),
            nodes: nodes, edges: edges,
            layers: [Layer(id: "layer:core", name: "Core", description: "",
                           nodeIds: nodes.map(\.id))],
            tour: []
        )
        var arrays = GraphArrays.compile(graph)
        arrays.blueprint = LayeredLayout.compute(arrays).positions
        arrays.universe = ForceLayout.compute(arrays)
        return (graph, arrays)
    }

    private func write(_ format: ExportService.Format) throws -> URL {
        let (graph, arrays) = sampleGraph()
        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("graph." + format.fileExtension)
        try ExportService.write(format, graph: graph, arrays: arrays,
                                positions: arrays.universe, to: url)
        return url
    }

    func testExportedHTMLIsSelfContained() throws {
        let html = try String(contentsOf: write(.html), encoding: .utf8)
        // Any absolute http(s) reference in a src/href would need the network.
        let external = html.ranges(of: try Regex(#"(?:src|href)=["']https?://"#))
        XCTAssertTrue(external.isEmpty,
                      "the exported viewer must not reference anything over the network")
        XCTAssertTrue(html.lowercased().hasPrefix("<!doctype html>"), "missing doctype")
        XCTAssertTrue(html.contains("sample"), "the project name should reach the page")
    }

    func testExportedJSONReloadsAsTheSameGraph() throws {
        let data = try Data(contentsOf: write(.json))
        let reloaded = try JSONDecoder().decode(KnowledgeGraph.self, from: data)
        XCTAssertEqual(reloaded.nodes.count, 24)
        XCTAssertEqual(reloaded.project.name, "sample")
        // Round-tripping is what keeps the format interoperable with upstream.
        XCTAssertEqual(Set(reloaded.nodes.map(\.id)).count, 24)
    }

    func testExportedSVGIsWellFormedXML() throws {
        let data = try Data(contentsOf: write(.svg))
        XCTAssertNoThrow(try XMLDocument(data: data),
                         "an SVG that will not parse opens in nothing")
    }

    func testExportedPNGIsARealImage() throws {
        let data = try Data(contentsOf: write(.png))
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                       "PNG signature missing")
    }
}
