import Foundation

/// Reads a Karpathy-pattern LLM wiki as a knowledge graph.
///
/// Ported from upstream's `parse-knowledge-base.py`. The pattern is three
/// layers: immutable raw sources, LLM-written markdown articles that link to
/// each other with `[[wikilinks]]`, and an `index.md` cataloguing them by
/// category.
///
/// Everything here is deterministic. Articles, sources, topics, wikilink edges
/// and category edges all come from the files themselves — an LLM is only
/// needed later to surface implicit relationships the text does not state
/// outright.
enum WikiParser {
    /// Files that are wiki infrastructure rather than content.
    static let infrastructureFiles: Set<String> = [
        "index.md", "log.md", "claude.md", "agents.md", "soul.md", "readme.md",
    ]

    private static let wikilink = Rx.compile(#"\[\[([^\]|]+)(?:\|([^\]]+))?\]\]"#)
    private static let frontmatter = Rx.compile(#"\A---\s*\n([\s\S]*?)\n---\s*\n"#)
    private static let heading = Rx.compile(#"^(#{1,6})\s+(.+)$"#, options: [.anchorsMatchLines])
    private static let indexSection = Rx.compile(#"^##\s+(.+)$"#, options: [.anchorsMatchLines])

    struct Detection: Sendable {
        var indexPath: String
        var articlePaths: [String]
        var sourcePaths: [String]
        var schemaPath: String?

        var articleCount: Int { articlePaths.count }
    }

    /// Whether a folder looks like a Karpathy wiki.
    ///
    /// The signal is an `index.md` plus several markdown files that actually
    /// link to each other. Requiring wikilinks is what stops any documentation
    /// folder from being mistaken for one — a `docs/` directory has an index
    /// and markdown too, but its files reference each other by path, not by
    /// `[[name]]`.
    static func detect(root: String, files: [ScannedFile]) -> Detection? {
        let markdown = files.filter { $0.fileCategory == .docs && $0.path.hasSuffix(".md") }
        guard markdown.count >= 3 else { return nil }

        // `index.md` at the top level, matched case-insensitively.
        guard let index = markdown.first(where: {
            PosixPath.directory(of: $0.path).isEmpty
                && PosixPath.basename($0.path).lowercased() == "index.md"
        }) else { return nil }

        var articles: [String] = []
        var linkedCount = 0
        for file in markdown {
            let base = PosixPath.basename(file.path).lowercased()
            if infrastructureFiles.contains(base) { continue }
            articles.append(file.path)
            if let text = FileRead.text(at: root + "/" + file.path, limit: ScanLimits.maxHeaderBytes),
               wikilink.matches(text) {
                linkedCount += 1
            }
        }
        // At least a third of the articles must actually use wikilinks.
        guard articles.count >= 2, linkedCount * 3 >= articles.count else { return nil }

        let sources = files
            .filter { $0.path.hasPrefix("raw/") || $0.path.hasPrefix("sources/") }
            .map(\.path)
        let schema = files.first {
            ["claude.md", "agents.md", "soul.md"].contains(PosixPath.basename($0.path).lowercased())
        }?.path

        return Detection(
            indexPath: index.path, articlePaths: articles.sortedStable(),
            sourcePaths: sources.sortedStable(), schemaPath: schema
        )
    }

    // MARK: - Parsing

    struct Result: Sendable {
        var graph: KnowledgeGraph
        var issues: [GraphIssue]
    }

    static func parse(
        root: String, detection: Detection, files: [ScannedFile], projectName: String
    ) -> Result {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var issues: [GraphIssue] = []
        var edgeKeys = Set<String>()

        func addEdge(_ edge: GraphEdge) {
            guard edge.source != edge.target, edgeKeys.insert(edge.dedupeKey).inserted else {
                return
            }
            edges.append(edge)
        }

        // ── Articles ──
        //
        // Indexed by several spellings of their name, because a wikilink is
        // written the way a human would say it — `[[Neural Networks]]`,
        // `[[neural-networks]]` and `neural_networks.md` all mean one article.
        var articleIDByKey: [String: String] = [:]
        var articleMeta: [(id: String, path: String, links: [String])] = []

        for path in detection.articlePaths {
            guard let text = FileRead.text(at: root + "/" + path) else {
                issues.append(GraphIssue(.dropped, .skippedFile,
                                         "Could not read \(path).", path: path))
                continue
            }

            let id = "article:" + path
            let title = self.title(of: text) ?? PosixPath.stem(path)
            let links = wikilinks(in: text)
            let headings = self.headings(in: text)

            for key in nameKeys(forTitle: title, path: path) where articleIDByKey[key] == nil {
                articleIDByKey[key] = id
            }
            articleMeta.append((id, path, links))

            nodes.append(GraphNode(
                id: id, type: .article, name: title, filePath: path,
                summary: firstParagraph(of: text) ?? GraphNode.pendingSummary,
                tags: ["wiki", "article"],
                complexity: GraphBuilder.complexity(ofLines: text.split(separator: "\n").count,
                                                    analysis: nil),
                knowledgeMeta: KnowledgeMeta(
                    wikilinks: links,
                    backlinks: [],
                    category: nil,
                    // A bounded preview, so the inspector can show the article
                    // without the whole graph carrying every wiki's full text.
                    content: String(text.prefix(1500))
                )
            ))
            _ = headings
        }

        // ── Wikilink edges ──
        var backlinks: [String: [String]] = [:]
        var unresolved = 0

        for article in articleMeta {
            for link in article.links {
                guard let targetID = articleIDByKey[normalise(link)] else {
                    // Reported rather than dropped: an unresolved wikilink is a
                    // real finding about the wiki — usually an article someone
                    // intended to write and has not yet.
                    unresolved += 1
                    issues.append(GraphIssue(
                        .autoCorrected, .unresolvedWikilink,
                        "\(PosixPath.basename(article.path)) links to [[\(link)]], which does not exist yet.",
                        path: article.path
                    ))
                    continue
                }
                addEdge(GraphEdge(source: article.id, target: targetID, type: .related))
                backlinks[targetID, default: []].append(article.id)
            }
        }

        for index in nodes.indices {
            if let incoming = backlinks[nodes[index].id] {
                nodes[index].knowledgeMeta?.backlinks = incoming.sortedStable()
            }
        }

        // ── Topics, from the index's section headings ──
        var topicIDs: [String: String] = [:]
        if let indexText = FileRead.text(at: root + "/" + detection.indexPath) {
            let sections = categorySections(in: indexText)
            for section in sections {
                let id = "topic:" + section.name.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                guard topicIDs[section.name] == nil else { continue }
                topicIDs[section.name] = id
                nodes.append(GraphNode(
                    id: id, type: .topic, name: section.name,
                    summary: "A category in this wiki's index.",
                    tags: ["wiki", "category"], complexity: .simple
                ))

                for link in section.links {
                    guard let articleID = articleIDByKey[normalise(link)] else { continue }
                    addEdge(GraphEdge(source: articleID, target: id, type: .categorized_under))
                    if let position = nodes.firstIndex(where: { $0.id == articleID }) {
                        nodes[position].knowledgeMeta?.category = section.name
                    }
                }
            }
        }

        // ── Raw sources ──
        for path in detection.sourcePaths {
            let id = "source:" + path
            nodes.append(GraphNode(
                id: id, type: .source, name: PosixPath.basename(path), filePath: path,
                summary: "A raw source document this wiki draws on.",
                tags: ["wiki", "source"], complexity: .simple
            ))
            // An article citing a source usually names its file.
            let stem = PosixPath.stem(path).lowercased()
            for article in articleMeta {
                guard let text = FileRead.text(at: root + "/" + article.path,
                                               limit: ScanLimits.maxHeaderBytes) else { continue }
                if text.lowercased().contains(stem) {
                    addEdge(GraphEdge(source: article.id, target: id, type: .cites))
                }
            }
        }

        if unresolved > 0 {
            issues.append(GraphIssue(
                .autoCorrected, .unresolvedWikilink,
                "\(unresolved) wikilink\(unresolved == 1 ? "" : "s") point at articles that do not exist yet."
            ))
        }

        // ── Layers: one per topic, so the canvas colours by category ──
        var layers: [Layer] = []
        var assigned = Set<String>()
        for (name, id) in topicIDs.sorted(by: { $0.key < $1.key }) {
            let members = nodes.filter { $0.knowledgeMeta?.category == name }.map(\.id)
            guard !members.isEmpty else { continue }
            assigned.formUnion(members)
            layers.append(Layer(id: "layer:" + id, name: name,
                                description: "Articles catalogued under \(name).",
                                nodeIds: members))
        }
        let uncategorised = nodes
            .filter { !assigned.contains($0.id) && $0.type != .topic }
            .map(\.id)
        if !uncategorised.isEmpty {
            layers.append(Layer(id: "layer:uncategorised", name: "Uncategorised",
                                description: "Articles the index does not list.",
                                nodeIds: uncategorised))
        }

        let graph = KnowledgeGraph(
            kind: .knowledge,
            project: ProjectMeta(
                name: projectName,
                languages: ["markdown"], frameworks: [],
                description: "A knowledge base of \(detection.articleCount) articles.",
                analyzedAt: ISO8601DateFormatter().string(from: Date()),
                gitCommitHash: GitProbe.headCommit(at: root) ?? ""
            ),
            nodes: nodes, edges: edges, layers: layers,
            tour: TourGenerator.generate(nodes: nodes, edges: edges, layers: layers,
                                         entryPoint: detection.indexPath)
        )
        return Result(graph: graph, issues: issues)
    }

    // MARK: - Text helpers

    static func wikilinks(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for groups in wikilink.allGroups(in: text) {
            guard let target = groups[group: 1]?
                .trimmingCharacters(in: .whitespaces), !target.isEmpty else { continue }
            if seen.insert(target.lowercased()).inserted { out.append(target) }
        }
        return out
    }

    /// The article's title: its first level-one heading, or its frontmatter
    /// `title:` if there is one.
    static func title(of text: String) -> String? {
        if let block = frontmatter.group(1, in: text) {
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("title:") else { continue }
                let value = trimmed.dropFirst(6)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !value.isEmpty { return value }
            }
        }
        for groups in heading.allGroups(in: text) {
            guard let hashes = groups[group: 1], hashes.count == 1,
                  let title = groups[group: 2] else { continue }
            return title.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The first real paragraph, used as a provisional summary so a wiki reads
    /// sensibly before any enrichment.
    static func firstParagraph(of text: String) -> String? {
        var body = text
        if let block = frontmatter.firstGroups(in: text)?[group: 0] {
            body = String(text.dropFirst(block.count))
        }
        for rawLine in body.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("```"),
                  !line.hasPrefix(">"), !line.hasPrefix("|"), !line.hasPrefix("-") else { continue }
            // Strip wikilink and markdown-link syntax so the summary reads as prose.
            var clean = wikilink.stringByReplacingMatches(
                in: line, options: [],
                range: NSRange(line.startIndex..<line.endIndex, in: line),
                withTemplate: "$1"
            )
            clean = clean.replacingOccurrences(of: "**", with: "")
            return ScanLimits.clamp(clean.trimmingCharacters(in: .whitespaces), 300)
        }
        return nil
    }

    static func headings(in text: String) -> [String] {
        heading.allGroups(in: text).compactMap { $0[group: 2] }
    }

    /// `## Category` sections of `index.md`, with the articles listed under each.
    static func categorySections(in indexText: String) -> [(name: String, links: [String])] {
        let lines = indexText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [(String, [String])] = []
        var current: String?
        var links: [String] = []

        for line in lines {
            if let name = indexSection.group(1, in: line) {
                if let previous = current { out.append((previous, links)) }
                current = name.trimmingCharacters(in: .whitespaces)
                links = []
                continue
            }
            guard current != nil else { continue }
            links.append(contentsOf: wikilinks(in: line))
        }
        if let previous = current { out.append((previous, links)) }
        return out
    }

    // MARK: - Name matching

    /// Every spelling a wikilink might use to refer to this article.
    static func nameKeys(forTitle title: String, path: String) -> [String] {
        [normalise(title), normalise(PosixPath.stem(path)), normalise(path)]
    }

    /// Collapses the ways people write the same name: case, spaces, hyphens and
    /// underscores are all equivalent, and a `.md` suffix is ignored.
    static func normalise(_ name: String) -> String {
        var text = name.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".md") { text = String(text.dropLast(3)) }
        return text
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
