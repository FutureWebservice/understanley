import XCTest

@testable import Understanley

/// Provider and enrichment behaviour.
///
/// No test here touches the network. Response handling is exercised against
/// recorded payloads, and the security rules — which are the part that would
/// actually hurt if wrong — are checked directly.
final class ProviderTests: XCTestCase {
    // MARK: - Endpoint security

    func testRemotePlainHTTPIsRefused() throws {
        // Source excerpts travel in the request body. A mistyped scheme must
        // not silently ship them in cleartext.
        XCTAssertThrowsError(
            try HTTPProvider(
                id: "custom", displayName: "Custom", destination: "x",
                format: .openAIChat, baseURL: "http://api.example.com",
                apiKey: nil, model: "m"
            )
        ) { error in
            guard case LLMError.insecureEndpoint = error else {
                return XCTFail("expected insecureEndpoint, got \(error)")
            }
        }
    }

    func testLoopbackPlainHTTPIsAllowed() throws {
        // Local model servers rarely bother with TLS, and there is no network
        // to intercept — refusing this would rule out Ollama and LM Studio.
        for host in ["http://127.0.0.1:11434", "http://localhost:1234", "http://[::1]:8080"] {
            XCTAssertNoThrow(
                try HTTPProvider(
                    id: "ollama", displayName: "Ollama", destination: "local",
                    format: .openAIChat, baseURL: host, apiKey: nil, model: "m"
                ),
                "should allow \(host)"
            )
        }
    }

    func testHTTPSIsAlwaysAllowed() {
        XCTAssertNoThrow(
            try HTTPProvider(
                id: "x", displayName: "X", destination: "x", format: .anthropicMessages,
                baseURL: "https://api.anthropic.com", apiKey: "k", model: "m"
            )
        )
    }

    func testNonsenseURLsAreRejected() {
        for bad in ["", "not a url", "ftp://files.example.com"] {
            XCTAssertThrowsError(
                try HTTPProvider(
                    id: "x", displayName: "X", destination: "x", format: .openAIChat,
                    baseURL: bad, apiKey: nil, model: "m"
                ),
                "should reject \(bad.isEmpty ? "<empty>" : bad)"
            )
        }
    }

    // MARK: - Response parsing

    func testParsesAnthropicResponse() throws {
        let payload = """
        {"id":"msg_1","type":"message","role":"assistant",
         "content":[{"type":"text","text":"first "},{"type":"text","text":"second"}],
         "usage":{"input_tokens":120,"output_tokens":45}}
        """
        let data = Data(payload.utf8)
        XCTAssertEqual(HTTPProvider.extractText(from: data, format: .anthropicMessages),
                       "first second")
        let usage = HTTPProvider.extractUsage(from: data, format: .anthropicMessages)
        XCTAssertEqual(usage.input, 120)
        XCTAssertEqual(usage.output, 45)
    }

    func testParsesOpenAIResponse() throws {
        let payload = """
        {"choices":[{"message":{"role":"assistant","content":"hello"}}],
         "usage":{"prompt_tokens":10,"completion_tokens":3}}
        """
        let data = Data(payload.utf8)
        XCTAssertEqual(HTTPProvider.extractText(from: data, format: .openAIChat), "hello")
        XCTAssertEqual(HTTPProvider.extractUsage(from: data, format: .openAIChat).input, 10)
    }

    func testMalformedResponsesReturnNilRatherThanThrowing() {
        // Self-hosted servers only approximate these formats; a shape surprise
        // should degrade to "no answer", not crash the run.
        for payload in ["{}", "[]", "not json", #"{"choices":[]}"#, #"{"content":"wrong type"}"#] {
            let data = Data(payload.utf8)
            XCTAssertNil(HTTPProvider.extractText(from: data, format: .openAIChat))
            XCTAssertNil(HTTPProvider.extractText(from: data, format: .anthropicMessages))
        }
    }

    func testErrorDetailIsExtractedFromCommonShapes() {
        let shapes = [
            #"{"error":{"message":"invalid api key"}}"#,
            #"{"error":"invalid api key"}"#,
            #"{"message":"invalid api key"}"#,
        ]
        for shape in shapes {
            XCTAssertTrue(HTTPProvider.errorDetail(from: Data(shape.utf8)).contains("invalid api key"))
        }
    }

    // MARK: - Prompt response extraction

    func testExtractsJSONFromWrappedResponses() {
        // Models add code fences and commentary despite being told not to.
        let wrapped = [
            #"{"items":[{"id":"a","summary":"s","tags":["t"]}]}"#,
            "```json\n{\"items\":[{\"id\":\"a\",\"summary\":\"s\",\"tags\":[\"t\"]}]}\n```",
            "Here is the analysis:\n{\"items\":[{\"id\":\"a\",\"summary\":\"s\",\"tags\":[\"t\"]}]}\nHope that helps!",
        ]
        for text in wrapped {
            let object = Prompts.extractJSONObject(from: text)
            XCTAssertNotNil(object, "failed on: \(text.prefix(40))")
            XCTAssertNotNil(object?["items"])
        }
    }

    func testJSONExtractionHandlesBracesInsideStrings() {
        // A summary legitimately containing a brace must not terminate the
        // object early.
        let text = #"{"items":[{"id":"a","summary":"uses a { literal } brace","tags":[]}]}"#
        let object = Prompts.extractJSONObject(from: text)
        let items = object?["items"] as? [[String: Any]]
        XCTAssertEqual(items?.first?["summary"] as? String, "uses a { literal } brace")
    }

    func testJSONExtractionReturnsNilOnGarbage() {
        XCTAssertNil(Prompts.extractJSONObject(from: "no json at all"))
        XCTAssertNil(Prompts.extractJSONObject(from: "{unclosed"))
    }

    // MARK: - Prompt construction

    func testPromptsCarryUntrustedContentFraming() {
        // A README full of imperatives, or a prompt-engineering repo with
        // literal jailbreaks in its fixtures, is ordinary input here.
        XCTAssertTrue(Prompts.fileAnalysisSystem(language: nil).contains("DATA"))
        XCTAssertTrue(Prompts.fileAnalysisSystem(language: nil).contains("never obeyed"))
        XCTAssertTrue(Prompts.tourSystem.contains("never obeyed"))
        XCTAssertTrue(Prompts.layerNamingSystem.contains("never obeyed"))
    }

    func testLanguageDirectiveIsAppendedWhenRequested() {
        XCTAssertFalse(Prompts.fileAnalysisSystem(language: nil).contains("Write every summary"))
        XCTAssertTrue(Prompts.fileAnalysisSystem(language: "Japanese").contains("Japanese"))
    }

    // MARK: - Merging

    func testApplyingDescriptionsKeepsDeterministicTags() {
        // `tested` and `entry-point` are facts the analyzer established. A model
        // has no standing to remove them.
        var graph = KnowledgeGraph(
            project: ProjectMeta(name: "p", languages: [], frameworks: [], description: "",
                                 analyzedAt: "", gitCommitHash: ""),
            nodes: [
                GraphNode(id: "file:a.ts", type: .file, name: "a.ts", filePath: "a.ts",
                          summary: GraphNode.pendingSummary, tags: ["tested", "typescript"]),
                GraphNode(id: "file:b.ts", type: .file, name: "b.ts", filePath: "b.ts",
                          summary: GraphNode.pendingSummary, tags: ["typescript"]),
            ],
            edges: [], layers: [], tour: []
        )

        graph.apply([
            "file:a.ts": Enricher.Description(summary: "Handles auth.", tags: ["api-handler"])
        ])

        XCTAssertEqual(graph.nodes[0].summary, "Handles auth.")
        XCTAssertTrue(graph.nodes[0].tags.contains("tested"))
        XCTAssertTrue(graph.nodes[0].tags.contains("api-handler"))
        XCTAssertTrue(graph.nodes[0].isEnriched)

        // Untouched nodes stay untouched.
        XCTAssertFalse(graph.nodes[1].isEnriched)
    }

    func testEnrichedFlagDistinguishesRealSummaries() {
        let pending = GraphNode(id: "a", type: .file, name: "a",
                                summary: GraphNode.pendingSummary, tags: [])
        let described = GraphNode(id: "b", type: .file, name: "b",
                                  summary: "Does a real thing.", tags: [])
        XCTAssertFalse(pending.isEnriched)
        XCTAssertTrue(described.isEnriched)
    }

    // MARK: - Journal

    func testJournalRoundTrips() throws {
        let root = NSTemporaryDirectory() + "ua-journal-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        var journal = Enricher.Journal()
        journal.nodes["file:a.ts"] = .init(
            fingerprint: "fp1",
            description: Enricher.Description(summary: "s", tags: ["t"])
        )
        journal.save(projectRoot: root)

        let reloaded = Enricher.Journal.load(projectRoot: root)
        XCTAssertEqual(reloaded.nodes["file:a.ts"]?.description.summary, "s")
        XCTAssertEqual(reloaded.nodes["file:a.ts"]?.fingerprint, "fp1")

        Enricher.Journal.clear(projectRoot: root)
        XCTAssertTrue(Enricher.Journal.load(projectRoot: root).nodes.isEmpty)
    }

    func testMissingJournalIsEmptyRatherThanAnError() {
        // A crash-safe cache must treat absence as a normal state.
        let journal = Enricher.Journal.load(projectRoot: "/nonexistent/\(UUID().uuidString)")
        XCTAssertTrue(journal.nodes.isEmpty)
    }

    // MARK: - Registry

    func testEveryProviderResolvesItsOwnSpec() {
        for spec in ProviderRegistry.all {
            XCTAssertEqual(ProviderRegistry.spec(spec.id)?.id, spec.id)
            XCTAssertFalse(spec.displayName.isEmpty)
            XCTAssertFalse(spec.destination.isEmpty, "\(spec.id) must say where data goes")
            XCTAssertFalse(spec.costNote.isEmpty, "\(spec.id) must state its cost")
        }
    }

    func testCLIProvidersNeedNoKey() {
        // The whole point of the CLI transports is reusing an existing sign-in.
        for id in ["claude-cli", "codex-cli"] {
            XCTAssertNil(ProviderRegistry.spec(id)?.keychainAccount)
        }
    }

    func testErrorsClassifyTransienceCorrectly() {
        // Retrying a bad key forever would just burn time; retrying a 503 is
        // exactly right.
        XCTAssertTrue(LLMError.rateLimited(retryAfter: 2).isTransient)
        XCTAssertTrue(LLMError.serverError(503, "").isTransient)
        XCTAssertTrue(LLMError.transport("timeout").isTransient)
        XCTAssertFalse(LLMError.unauthorized("X").isTransient)
        XCTAssertFalse(LLMError.serverError(400, "").isTransient)
        XCTAssertFalse(LLMError.notConfigured("X").isTransient)
    }

    func testEveryErrorExplainsWhatToDo() {
        let errors: [LLMError] = [
            .notConfigured("Anthropic"), .executableMissing("claude"),
            .unauthorized("OpenAI"), .rateLimited(retryAfter: 5),
            .serverError(500, "boom"), .transport("offline"),
            .emptyResponse, .insecureEndpoint("api.example.com"),
        ]
        for error in errors {
            let message = error.localizedDescription
            XCTAssertFalse(message.isEmpty)
            // No raw enum names or Swift types leaking into the UI.
            XCTAssertFalse(message.contains("LLMError"), "leaked type name: \(message)")
        }
    }
}

/// The enrichment journal — the thing that means a description is paid for once.
///
/// It used to be keyed by *batch* fingerprint, which made it useless for its
/// main job: batching depends on the provider's capacity, so switching provider
/// or re-analyzing into a different grouping matched nothing and every summary
/// was bought again. Keyed per node it replays regardless.
final class EnrichmentJournalTests: XCTestCase {
    private func graph(_ nodes: [GraphNode]) -> KnowledgeGraph {
        KnowledgeGraph(
            project: ProjectMeta(name: "t", languages: [], frameworks: [],
                                 description: "", analyzedAt: "", gitCommitHash: ""),
            nodes: nodes, edges: [], layers: [], tour: []
        )
    }

    private func node(_ id: String, lines: LineRange? = nil) -> GraphNode {
        GraphNode(id: id, type: .function, name: id, filePath: "a.ts",
                  lineRange: lines, summary: GraphNode.pendingSummary, tags: [])
    }

    func testReplaysDescriptionsForUnchangedNodes() {
        let g = graph([node("function:a.ts:one"), node("function:a.ts:two")])
        let prints = Enricher.fingerprints(for: g.nodes, graph: g)

        var journal = Enricher.Journal()
        for id in prints.keys {
            journal.nodes[id] = .init(
                fingerprint: prints[id]!,
                description: Enricher.Description(summary: "written earlier", tags: ["t"])
            )
        }

        let replayed = journal.replay(for: g, fingerprints: prints)
        XCTAssertEqual(replayed.count, 2)
        XCTAssertEqual(replayed["function:a.ts:one"]?.summary, "written earlier")
    }

    func testDropsDescriptionsWhoseNodeChanged() {
        let before = graph([node("function:a.ts:one", lines: LineRange(1, 10))])
        let printsBefore = Enricher.fingerprints(for: before.nodes, graph: before)
        var journal = Enricher.Journal()
        journal.nodes["function:a.ts:one"] = .init(
            fingerprint: printsBefore["function:a.ts:one"]!,
            description: Enricher.Description(summary: "describes the old body", tags: [])
        )

        // Same node, different span — the code it describes has moved or grown,
        // so the sentence written about it can no longer be trusted.
        let after = graph([node("function:a.ts:one", lines: LineRange(1, 40))])
        let printsAfter = Enricher.fingerprints(for: after.nodes, graph: after)
        XCTAssertTrue(journal.replay(for: after, fingerprints: printsAfter).isEmpty)
    }

    func testReplayIsIndependentOfHowNodesWereBatched() {
        // The whole point: a journal written by a provider that batches 14 at a
        // time must still replay for one that batches 1.
        let g = graph((0..<20).map { node("function:a.ts:f\($0)") })
        let prints = Enricher.fingerprints(for: g.nodes, graph: g)
        var journal = Enricher.Journal()
        for (id, print) in prints {
            journal.nodes[id] = .init(
                fingerprint: print,
                description: Enricher.Description(summary: "s", tags: [])
            )
        }
        XCTAssertEqual(journal.replay(for: g, fingerprints: prints).count, 20)
    }
}

