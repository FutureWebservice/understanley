import XCTest

@testable import Understanley

/// Karpathy-wiki detection and parsing.
///
/// The risk here runs both ways: failing to recognise a wiki loses its only
/// structure, and over-eagerly recognising one turns every `docs/` folder into
/// a knowledge graph with no code in it.
final class WikiTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "ua-wiki-" + UUID().uuidString
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

    /// A minimal but realistic wiki.
    private func buildWiki() throws {
        try write("index.md", """
        # My Wiki

        ## Machine Learning

        - [[Neural Networks]]
        - [[Backpropagation]]

        ## Infrastructure

        - [[Kubernetes]]
        """)
        try write("neural-networks.md", """
        # Neural Networks

        Layered function approximators trained by gradient descent.

        Training relies on [[Backpropagation]] to assign credit.
        """)
        try write("backpropagation.md", """
        # Backpropagation

        The reverse-mode differentiation algorithm used to train
        [[Neural Networks]]. Described in raw/rumelhart1986.
        """)
        try write("kubernetes.md", """
        # Kubernetes

        Container orchestration. Unrelated to [[Neural Networks]] but linked
        here to test cross-category edges. Also mentions [[Nonexistent Page]].
        """)
        try write("raw/rumelhart1986.txt", "Learning representations by back-propagating errors.")
    }

    private func scan() async -> ScanResult {
        await ProjectScanner(diagnostics: DiagnosticsCollector()).scan(projectRoot: root)
    }

    // MARK: - Detection

    func testDetectsAWiki() async throws {
        try buildWiki()
        let files = await scan().files
        let detection = WikiParser.detect(root: root, files: files)
        XCTAssertNotNil(detection)
        XCTAssertEqual(detection?.articleCount, 3)
        XCTAssertEqual(detection?.sourcePaths, ["raw/rumelhart1986.txt"])
    }

    func testOrdinaryDocsFolderIsNotAWiki() async throws {
        // Same shape — an index and several markdown files — but the files
        // reference each other by path, not by wikilink. Treating this as a
        // knowledge base would discard the actual codebase.
        try write("index.md", "# Docs\n\nSee [setup](setup.md) and [api](api.md).")
        try write("setup.md", "# Setup\n\nInstall things. See [api](api.md).")
        try write("api.md", "# API\n\nEndpoints.")
        try write("guide.md", "# Guide\n\nMore prose.")
        let files = await scan().files
        XCTAssertNil(WikiParser.detect(root: root, files: files))
    }

    func testFolderWithoutAnIndexIsNotAWiki() async throws {
        try write("a.md", "# A\n\nLinks to [[B]].")
        try write("b.md", "# B\n\nLinks to [[A]].")
        try write("c.md", "# C\n\nLinks to [[A]].")
        let files = await scan().files
        XCTAssertNil(WikiParser.detect(root: root, files: files))
    }

    // MARK: - Parsing

    func testParsesArticlesLinksAndCategories() async throws {
        try buildWiki()
        let scanResult = await scan()
        let detection = try XCTUnwrap(WikiParser.detect(root: root, files: scanResult.files))
        let result = WikiParser.parse(
            root: root, detection: detection, files: scanResult.files, projectName: "wiki"
        )
        let graph = result.graph

        XCTAssertEqual(graph.kind, .knowledge)

        let articles = graph.nodes.filter { $0.type == .article }
        XCTAssertEqual(articles.count, 3)
        // Titles come from the level-one heading, not the filename.
        XCTAssertTrue(articles.contains { $0.name == "Neural Networks" })

        // Wikilinks become `related` edges in both directions where both
        // articles exist.
        XCTAssertTrue(graph.edges.contains {
            $0.type == .related
                && $0.source == "article:neural-networks.md"
                && $0.target == "article:backpropagation.md"
        })

        // Index sections become topics, with articles filed under them.
        let topics = graph.nodes.filter { $0.type == .topic }
        XCTAssertEqual(Set(topics.map(\.name)), ["Machine Learning", "Infrastructure"])
        XCTAssertTrue(graph.edges.contains {
            $0.type == .categorized_under && $0.source == "article:kubernetes.md"
        })

        // Raw documents become sources, cited by the articles that mention them.
        XCTAssertTrue(graph.nodes.contains { $0.type == .source })
        XCTAssertTrue(graph.edges.contains { $0.type == .cites })
    }

    func testUnresolvedWikilinksAreReportedNotDropped() async throws {
        try buildWiki()
        let scanResult = await scan()
        let detection = try XCTUnwrap(WikiParser.detect(root: root, files: scanResult.files))
        let result = WikiParser.parse(
            root: root, detection: detection, files: scanResult.files, projectName: "wiki"
        )
        // `[[Nonexistent Page]]` is a real finding about the wiki — usually an
        // article someone meant to write. Silently dropping it hides that.
        XCTAssertTrue(result.issues.contains {
            $0.category == .unresolvedWikilink && $0.message.contains("Nonexistent Page")
        })
        // And it produces no dangling edge.
        let ids = Set(result.graph.nodes.map(\.id))
        for edge in result.graph.edges {
            XCTAssertTrue(ids.contains(edge.source))
            XCTAssertTrue(ids.contains(edge.target))
        }
    }

    func testBacklinksArePopulated() async throws {
        try buildWiki()
        let scanResult = await scan()
        let detection = try XCTUnwrap(WikiParser.detect(root: root, files: scanResult.files))
        let graph = WikiParser.parse(
            root: root, detection: detection, files: scanResult.files, projectName: "wiki"
        ).graph

        let neural = try XCTUnwrap(graph.nodes.first { $0.id == "article:neural-networks.md" })
        // Both Backpropagation and Kubernetes link to it.
        XCTAssertEqual(neural.knowledgeMeta?.backlinks?.count, 2)
    }

    func testPipelineChoosesWikiModeAutomatically() async throws {
        try buildWiki()
        let graph = try await AnalysisPipeline(diagnostics: DiagnosticsCollector())
            .run(projectRoot: root)
        XCTAssertEqual(graph.kind, .knowledge)
        XCTAssertTrue(graph.nodes.contains { $0.type == .article })
    }

    // MARK: - Name matching

    func testWikilinkNamesMatchAcrossSpellings() {
        // `[[Neural Networks]]`, `[[neural-networks]]` and `neural_networks.md`
        // all mean one article. A link is written the way a human says it.
        let variants = ["Neural Networks", "neural-networks", "neural_networks",
                        "NEURAL NETWORKS", "neural-networks.md"]
        let normalised = Set(variants.map(WikiParser.normalise))
        XCTAssertEqual(normalised.count, 1, "spellings did not collapse: \(normalised)")
    }

    func testExtractsWikilinksIncludingAliases() {
        let text = "See [[Target]] and [[Other|displayed as this]] and [[Target]] again."
        // Aliased links resolve to their target, and repeats collapse.
        XCTAssertEqual(WikiParser.wikilinks(in: text), ["Target", "Other"])
    }

    func testTitlePrefersFrontmatterThenHeading() {
        XCTAssertEqual(
            WikiParser.title(of: "---\ntitle: From Frontmatter\n---\n\n# From Heading\n"),
            "From Frontmatter"
        )
        XCTAssertEqual(WikiParser.title(of: "# From Heading\n\nBody."), "From Heading")
        XCTAssertNil(WikiParser.title(of: "Just body text."))
    }

    func testFirstParagraphSkipsStructureAndStripsSyntax() {
        let text = """
        ---
        title: T
        ---

        # Heading

        > a quote

        The real **first** paragraph mentions [[Something]].
        """
        let summary = try? XCTUnwrap(WikiParser.firstParagraph(of: text))
        XCTAssertEqual(summary, "The real first paragraph mentions Something.")
    }

    func testIndexSectionsCarryTheirLinks() {
        let sections = WikiParser.categorySections(in: """
        # Index

        ## Alpha

        - [[One]]
        - [[Two]]

        ## Beta

        - [[Three]]
        """)
        XCTAssertEqual(sections.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(sections.first?.links, ["One", "Two"])
        XCTAssertEqual(sections.last?.links, ["Three"])
    }
}

/// Domain extraction — the one pass that cannot be computed.
///
/// The parser is deliberately tolerant: a model that gets nine domains right
/// and malforms the tenth should cost the tenth, not the pass. These lock that
/// in, along with the invariant that matters most — a model may not invent
/// node ids, because a fabricated link is a lie about the code.
final class DomainExtractorTests: XCTestCase {
    func testParsesDomainsFlowsAndSteps() {
        let json = """
        Here you go:
        ```json
        {"domains":[{"name":"Billing","summary":"Money in.","nodeIds":["file:a.ts"],
          "flows":[{"name":"Checkout","summary":"Buy.","steps":[
            {"name":"Validate card","summary":"Check it.","nodeId":"function:a.ts:v"},
            {"name":"Charge","summary":"Take it."}]}]}]}
        ```
        """
        let domains = DomainExtractor.parse(json)
        XCTAssertEqual(domains.count, 1)
        XCTAssertEqual(domains[0].name, "Billing")
        XCTAssertEqual(domains[0].flows.count, 1)
        XCTAssertEqual(domains[0].flows[0].steps.map(\.name), ["Validate card", "Charge"])
        XCTAssertEqual(domains[0].flows[0].steps[0].nodeId, "function:a.ts:v")
        XCTAssertNil(domains[0].flows[0].steps[1].nodeId)
    }

    func testKeepsWellFormedDomainsAndDropsTheRest() {
        let json = """
        {"domains":[{"name":"Good","flows":[]},{"summary":"no name"},{"name":"  "},
                    {"name":"AlsoGood","flows":[]}]}
        """
        XCTAssertEqual(DomainExtractor.parse(json).map(\.name), ["Good", "AlsoGood"])
    }

    func testGarbageParsesToNothingRatherThanCrashing() {
        for text in ["", "no json here", "{}", "{\"domains\": \"not an array\"}", "{[}"] {
            XCTAssertTrue(DomainExtractor.parse(text).isEmpty, text)
        }
    }

    func testSlugsAreStableAndSafe() {
        XCTAssertEqual(DomainExtractor.slug("Billing & Payments"), "billing-payments")
        XCTAssertEqual(DomainExtractor.slug("  Search  "), "search")
        XCTAssertEqual(DomainExtractor.slug("!!!"), "domain")
        // Same input, same id — a re-run must replace a domain, not duplicate it.
        XCTAssertEqual(DomainExtractor.slug("User Accounts"), DomainExtractor.slug("User Accounts"))
    }
}

