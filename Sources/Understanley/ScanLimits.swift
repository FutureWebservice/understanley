import Foundation

/// Hard caps on every piece of untrusted input the app touches.
///
/// The analyzer walks directories chosen by the user and owned by other
/// programs, so the input is entirely outside this app's control: a "source
/// file" can be a gigabyte of minified output, a directory can contain a
/// symlink loop, and a file called `config.json` can be arbitrary binary. Every
/// read path below is bounded by one of these constants, and nothing in the
/// codebase reads unbounded — that is what keeps a hostile repository from
/// turning into a hang or an OOM.
///
/// Deliberately one flat enum rather than per-subsystem constants: when a limit
/// needs raising, this file is the only place to look.
enum ScanLimits {
    // MARK: File reads

    /// Largest file read whole into memory for analysis. Beyond this a file is
    /// counted and categorised but not parsed.
    static let maxWholeFileBytes = 8 * 1024 * 1024

    /// Largest file the source viewer will display. Matches upstream's
    /// `MAX_SOURCE_FILE_BYTES`.
    static let maxSourceFileBytes = 1024 * 1024

    /// Bytes read when only a file's head matters (manifest sniffing, encoding
    /// probes).
    static let maxHeaderBytes = 256 * 1024

    // MARK: Tree walking

    /// Directory depth beyond which descent stops. Also the backstop against
    /// symlink loops, alongside skipping symlinks outright.
    static let maxDirectoryDepth = 24

    /// Files considered in a single project. A tree larger than this is
    /// truncated with a visible warning rather than silently sampled.
    static let maxFilesPerProject = 50_000

    // MARK: Graph

    /// Nodes retained in one graph. Past this the renderer's level-of-detail
    /// ladder stops being able to hide the cost.
    static let maxGraphNodes = 200_000

    /// Edges retained in one graph.
    static let maxGraphEdges = 500_000

    // MARK: Subprocesses

    /// Wall-clock budget for a single `git` invocation.
    static let gitTimeout: TimeInterval = 5

    /// Largest stdout accepted from a `git` invocation.
    static let gitMaxOutputBytes = 4 * 1024 * 1024

    /// Bounds on a domain pass. A model asked for "the domains" of a large
    /// project will happily invent fifty; past a dozen the view stops being a
    /// map and becomes another list.
    static let maxDomains = 12
    static let maxFlowsPerDomain = 6
    static let maxStepsPerFlow = 8
    /// Nodes described to the model when deriving domains. The signal is in the
    /// layer, the path and the name, so this can be far larger than an
    /// enrichment batch and still fit.
    static let maxDomainContextNodes = 220

    /// Wall-clock budget for one enrichment batch handed to a CLI provider.
    /// Generous because a cold model load is legitimately slow.
    static let cliProviderTimeout: TimeInterval = 300

    // MARK: Helpers

    /// Reads a file only if it is within `limit`, memory-mapping when safe.
    /// Returns nil for anything too large, unreadable, or not a regular file —
    /// callers treat nil as "skip", never as an error worth surfacing.
    static func dataIfSmallEnough(_ path: String, limit: Int = maxWholeFileBytes) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? Int, size <= limit
        else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
    }

    /// Truncates a string to `limit` characters, marking that it was cut so a
    /// clipped value never masquerades as a complete one.
    static func clamp(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }
}
