import Foundation

/// Fuzzy search over the graph.
///
/// Ports the scoring upstream gets from Fuse.js: four weighted fields, a 0.4
/// relevance threshold, and query tokens combined as OR so `"auth handler"`
/// finds nodes matching either word. Score runs **0 = perfect, 1 = worst**,
/// matching upstream's convention — the UI shows `(1 - score)` as a percentage.
struct SearchEngine: Sendable {
    /// Weights from upstream's Fuse configuration.
    private static let nameWeight = 0.4
    private static let tagsWeight = 0.3
    private static let summaryWeight = 0.2
    private static let notesWeight = 0.1
    private static let threshold = 0.4

    struct Entry: Sendable {
        var index: Int
        var name: String
        var tags: String
        var summary: String
        var notes: String
        var type: NodeType
    }

    struct Hit: Sendable {
        var index: Int
        var score: Double
    }

    private let entries: [Entry]

    init(graph: KnowledgeGraph) {
        entries = graph.nodes.enumerated().map { index, node in
            Entry(
                index: index,
                name: node.name.lowercased(),
                tags: node.tags.joined(separator: " ").lowercased(),
                // Placeholder summaries carry no signal and would let every
                // unenriched node match the same words.
                summary: node.isEnriched ? node.summary.lowercased() : "",
                notes: (node.languageNotes ?? "").lowercased(),
                type: node.type
            )
        }
    }

    func search(_ query: String, limit: Int = 50, types: Set<NodeType>? = nil) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var hits: [Hit] = []
        for entry in entries {
            if let types, !types.contains(entry.type) { continue }
            // OR across tokens: the best-matching token decides.
            var best = 1.0
            for token in tokens {
                best = min(best, score(entry: entry, token: token))
                if best == 0 { break }
            }
            if best <= Self.threshold {
                hits.append(Hit(index: entry.index, score: best))
            }
        }

        // Ties break on index so results never reshuffle between identical
        // queries.
        hits.sort { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
        return Array(hits.prefix(limit))
    }

    /// Weighted best-field score.
    ///
    /// Each field's raw score is scaled by how much less it is worth than the
    /// name field, then the best scaled score wins. A perfect name match
    /// therefore scores 0, while the same text found only in a summary scores
    /// twice as poorly — which is the ranking a reader expects.
    private func score(entry: Entry, token: String) -> Double {
        var best = 1.0
        best = min(best, fieldScore(entry.name, token) * (Self.nameWeight / Self.nameWeight))
        best = min(best, fieldScore(entry.tags, token) * (Self.nameWeight / Self.tagsWeight))
        best = min(best, fieldScore(entry.summary, token) * (Self.nameWeight / Self.summaryWeight))
        best = min(best, fieldScore(entry.notes, token) * (Self.nameWeight / Self.notesWeight))
        return min(1, best)
    }

    /// How well `token` matches `text`, 0 best.
    private func fieldScore(_ text: String, _ token: String) -> Double {
        guard !text.isEmpty else { return 1 }
        if text == token { return 0 }
        if text.hasPrefix(token) { return 0.05 }

        if let range = text.range(of: token) {
            // Later matches are weaker — a hit at the start of a name is more
            // meaningful than one buried at the end.
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            let positional = min(0.2, Double(offset) / Double(max(1, text.count)) * 0.2)
            // A short query matching a long string is weaker evidence.
            let coverage = 1 - Double(token.count) / Double(max(token.count, text.count))
            return 0.12 + positional + coverage * 0.18
        }

        // Subsequence fallback, so `grphbldr` still finds `graph-builder`.
        return subsequenceScore(text, token)
    }

    /// Score for `token`'s characters appearing in order within `text`.
    ///
    /// Consecutive runs are rewarded: matching a contiguous chunk is much
    /// stronger evidence than the same letters scattered across the string,
    /// and without that distinction almost everything matches almost
    /// everything.
    private func subsequenceScore(_ text: String, _ token: String) -> Double {
        let haystack = Array(text)
        let needle = Array(token)
        guard needle.count >= 2, needle.count <= haystack.count else { return 1 }

        var haystackIndex = 0
        var matched = 0
        var runs = 0
        var previousWasMatch = false

        for character in needle {
            var found = false
            while haystackIndex < haystack.count {
                if haystack[haystackIndex] == character {
                    found = true
                    haystackIndex += 1
                    break
                }
                haystackIndex += 1
                previousWasMatch = false
            }
            guard found else { return 1 }
            matched += 1
            if previousWasMatch { runs += 1 }
            previousWasMatch = true
        }
        guard matched == needle.count else { return 1 }

        let contiguity = Double(runs) / Double(max(1, needle.count - 1))
        let density = Double(needle.count) / Double(haystack.count)
        // Never better than a real substring match: this is the weakest form of
        // evidence and should rank below it.
        return max(0.26, 0.40 - contiguity * 0.12 - density * 0.05)
    }
}
