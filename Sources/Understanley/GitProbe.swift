import Foundation

/// Reads git state without a git library.
///
/// Ported from upstream's `staleness.ts`, including its pathspec exclusions:
/// the analysis directory is our own output, so changes to it must never make a
/// graph look stale against itself.
enum GitProbe {
    /// Excludes the analysis directory from every diff, in both its current and
    /// legacy locations.
    private static let projectPathspec = [
        "--", ".",
        ":(exclude).understand-anything", ":(exclude).understand-anything/**",
        ":(exclude).ua", ":(exclude).ua/**",
    ]

    /// Whether a graph still describes the working tree.
    enum Freshness: Sendable, Equatable {
        /// Graph commit equals HEAD and nothing is modified.
        case fresh
        /// Graph commit equals HEAD but the working tree has uncommitted changes.
        case dirty(changedFiles: [String])
        /// History has moved.
        case stale(relation: Relation, commitsBehind: Int, commitsAhead: Int, changedFiles: [String])
        /// Could not be determined. Deliberately distinct from `fresh` — an
        /// unanswerable question is not a clean bill of health.
        case unknown(reason: UnknownReason)

        enum Relation: String, Sendable {
            case behind, ahead, diverged
        }

        enum UnknownReason: String, Sendable {
            case missingGraphCommit = "missing-graph-commit"
            case gitHeadUnavailable = "git-head-unavailable"
            case graphCommitUnavailable = "graph-commit-unavailable"
            case gitCommandTimeout = "git-command-timeout"
            case notAGitRepository = "not-a-git-repository"

            var explanation: String {
                switch self {
                case .missingGraphCommit:
                    return "This graph was built without a commit reference, so it cannot be compared to your current code."
                case .gitHeadUnavailable:
                    return "Could not read the current commit. The repository may have no commits yet."
                case .graphCommitUnavailable:
                    return "The commit this graph was built from is no longer in the repository — it may have been rebased or garbage-collected."
                case .gitCommandTimeout:
                    return "Git did not respond in time. On a very large repository this can happen under load."
                case .notAGitRepository:
                    return "This folder is not a git repository, so changes cannot be tracked."
                }
            }
        }
    }

    private static var gitPath: String? { Subprocess.which("git") }

    private static func run(_ arguments: [String], at root: String) -> CommandResult? {
        guard let git = gitPath else { return nil }
        return try? Subprocess.run(git, arguments, cwd: root)
    }

    /// True when `root` is inside a git working tree.
    static func isRepository(at root: String) -> Bool {
        guard let result = run(["rev-parse", "--is-inside-work-tree"], at: root) else { return false }
        return result.succeeded && result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Current HEAD commit hash, or nil outside a repository or before the
    /// first commit.
    static func headCommit(at root: String) -> String? {
        guard let result = run(["rev-parse", "HEAD"], at: root), result.succeeded else { return nil }
        let hash = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// Files modified, staged or untracked right now.
    static func dirtyFiles(at root: String) -> [String] {
        var files = Set<String>()
        for arguments in [
            ["diff", "--cached", "--name-only", "-z", "--relative"] + projectPathspec,
            ["diff", "--name-only", "-z", "--relative"] + projectPathspec,
            ["ls-files", "--others", "--exclude-standard", "-z"] + projectPathspec,
        ] {
            guard let result = run(arguments, at: root), result.succeeded else { continue }
            files.formUnion(result.stdoutNulFields)
        }
        return files.sortedStable()
    }

    /// Files that changed between two commits.
    static func changedFiles(at root: String, from: String, to: String = "HEAD") -> [String] {
        let arguments = ["diff", "--name-only", "-z", "--relative", from, to] + projectPathspec
        guard let result = run(arguments, at: root), result.succeeded else { return [] }
        return result.stdoutNulFields
    }

    /// Compares a graph's commit against the current working tree.
    static func freshness(at root: String, graphCommit: String) -> Freshness {
        guard !graphCommit.isEmpty else { return .unknown(reason: .missingGraphCommit) }
        guard isRepository(at: root) else { return .unknown(reason: .notAGitRepository) }
        guard let head = headCommit(at: root) else { return .unknown(reason: .gitHeadUnavailable) }

        // Verify the graph's commit still exists — a rebase or a garbage
        // collection can remove it, and diffing against a missing object
        // produces a confusing error rather than an answer.
        guard let verify = run(
            ["rev-parse", "--verify", "--end-of-options", graphCommit + "^{commit}"], at: root
        ) else { return .unknown(reason: .gitCommandTimeout) }
        guard verify.succeeded else { return .unknown(reason: .graphCommitUnavailable) }

        let dirty = dirtyFiles(at: root)
        let committed = graphCommit == head ? [] : changedFiles(at: root, from: graphCommit, to: head)

        if committed.isEmpty {
            return dirty.isEmpty ? .fresh : .dirty(changedFiles: dirty)
        }

        var behind = 0
        var ahead = 0
        if let counts = run(
            ["rev-list", "--left-right", "--count", "\(graphCommit)...\(head)"] + projectPathspec,
            at: root
        ), counts.succeeded {
            let parts = counts.stdoutText.split(whereSeparator: { $0 == "\t" || $0 == " " })
            // `--left-right --count` prints "<left>\t<right>": commits only in
            // the graph's history, then commits only in HEAD's.
            if parts.count == 2 {
                ahead = Int(parts[0]) ?? 0
                behind = Int(parts[1]) ?? 0
            }
        }

        let graphIsAncestor = run(
            ["merge-base", "--is-ancestor", graphCommit, head], at: root
        )?.succeeded ?? false
        let headIsAncestor = run(
            ["merge-base", "--is-ancestor", head, graphCommit], at: root
        )?.succeeded ?? false

        let relation: Freshness.Relation = graphIsAncestor ? .behind
            : (headIsAncestor ? .ahead : .diverged)

        return .stale(
            relation: relation,
            commitsBehind: behind,
            commitsAhead: ahead,
            changedFiles: Array(Set(committed).union(dirty)).sortedStable()
        )
    }
}
