import CryptoKit
import Foundation

// Small shared primitives. Kept in one file because each is a handful of lines
// and they are used from nearly every stage of the pipeline.

// MARK: - Ordering

/// Lexicographic comparison over UTF-16 code units.
///
/// This is not the same as Swift's `<` on `String`, which compares by Unicode
/// canonical ordering. The upstream pipeline sorts paths with JavaScript's
/// `<`, which is UTF-16 code-unit order, and that ordering is baked into the
/// output: batch composition, node emission order, and therefore the content
/// digest all depend on it. The two agree for ASCII and disagree for
/// surrogate-pair characters versus U+E000–U+FFFF, so a repository with an
/// emoji in a filename would otherwise produce a different graph here than
/// upstream — and golden-graph comparison would report a phantom divergence.
func compareUTF16(_ a: String, _ b: String) -> ComparisonResult {
    if a == b { return .orderedSame }
    var ai = a.utf16.makeIterator()
    var bi = b.utf16.makeIterator()
    while true {
        switch (ai.next(), bi.next()) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?):
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
    }
}

extension Sequence where Element == String {
    /// Sorted in upstream's UTF-16 code-unit order.
    func sortedStable() -> [String] {
        sorted { compareUTF16($0, $1) == .orderedAscending }
    }
}

extension Sequence {
    /// Sorted by a string key in upstream's UTF-16 code-unit order.
    func sortedStable(by key: (Element) -> String) -> [Element] {
        sorted { compareUTF16(key($0), key($1)) == .orderedAscending }
    }
}

// MARK: - POSIX paths

/// Project-relative path arithmetic.
///
/// Deliberately string-based rather than `URL`-based: these paths are graph
/// identity, not filesystem locations. `URL` normalises percent-encoding and
/// resolves symlinks, both of which would silently change a node id.
enum PosixPath {
    /// Normalises separators and drops empty segments.
    ///
    /// Note this strips a leading slash, matching upstream's `toPosix`. An
    /// absolute-looking input becomes relative, which is the desired behaviour
    /// here — every path in the graph is relative to the project root.
    static func normalize(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).joined(separator: "/")
    }

    /// Everything before the last `/`, or `""` at the root.
    static func directory(of path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<idx])
    }

    /// Everything after the last `/`.
    static func basename(_ path: String) -> String {
        guard let idx = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: idx)...])
    }

    /// Lowercased extension including the dot (`".ts"`), or `""` when there is
    /// none. A leading dot does not count as an extension, so `.gitignore`
    /// returns `""` rather than `".gitignore"`.
    static func fileExtension(_ path: String) -> String {
        let base = basename(path)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[dot...]).lowercased()
    }

    /// Filename without its extension.
    static func stem(_ path: String) -> String {
        let base = basename(path)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return base }
        return String(base[base.startIndex..<dot])
    }

    /// Resolves `relative` against directory `dir`, collapsing `.` and `..`.
    /// Returns `""` if the path escapes above the project root — callers treat
    /// that as unresolvable rather than reaching outside the tree.
    static func resolve(_ dir: String, _ relative: String) -> String {
        var stack: [Substring] = []
        for part in dir.split(separator: "/") where part != "." {
            stack.append(part)
        }
        for part in relative.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                if stack.isEmpty { return "" }
                stack.removeLast()
                continue
            }
            stack.append(part)
        }
        return stack.joined(separator: "/")
    }

    /// Joins segments, skipping empties.
    static func join(_ parts: String...) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// First path segment, or nil for a root-level file.
    static func topDirectory(_ path: String) -> String? {
        let dir = directory(of: path)
        guard !dir.isEmpty else { return nil }
        return String(dir.split(separator: "/")[0])
    }

    /// Rejects paths that would escape the project root or smuggle a NUL.
    /// Used anywhere a path crosses a trust boundary — the source viewer's
    /// allowlist check, and any path read out of a graph file the app did not
    /// write itself.
    static func isSafeRelative(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if path.contains("\0") { return false }
        if path.hasPrefix("/") { return false }
        // Reject a drive-letter prefix, which is absolute on Windows and would
        // otherwise sail through the leading-slash check.
        if path.count >= 2, path[path.index(path.startIndex, offsetBy: 1)] == ":" { return false }
        return !path.split(separator: "/").contains("..")
    }
}

// MARK: - Hashing

enum Hash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Deterministic 64-bit hash used for per-node visual jitter (breathing
    /// phase, starfield seeds). Not `Hasher`, which is seeded per process and
    /// would make the render differ between launches.
    static func stable64(_ string: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a offset basis
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100_0000_01b3 // FNV prime
        }
        return h
    }
}

// MARK: - Bounded reading

enum FileRead {
    /// Reads a file as UTF-8, falling back to a lossy decode rather than
    /// failing. Source trees contain latin-1 fragments, BOMs and truncated
    /// multibyte sequences; refusing to parse those would drop real files from
    /// the graph, and a slightly mangled identifier is a far smaller loss than
    /// a missing node.
    static func text(at path: String, limit: Int = ScanLimits.maxWholeFileBytes) -> String? {
        guard let data = ScanLimits.dataIfSmallEnough(path, limit: limit) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when the buffer contains a NUL byte, the same heuristic upstream
    /// uses to refuse a binary preview.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(ScanLimits.maxHeaderBytes).contains(0)
    }

    /// `wc -l` semantics: the number of newline bytes. Deliberately not
    /// `split("\n").count`, which is one higher on a newline-terminated file —
    /// upstream's `sizeLines` uses the byte count and the two must agree.
    static func countNewlines(_ data: Data) -> Int {
        data.reduce(into: 0) { acc, byte in if byte == 0x0A { acc += 1 } }
    }
}

// MARK: - Subprocess

/// Result of running a command: exit status plus captured output.
struct CommandResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: String

    var succeeded: Bool { status == 0 }
    var stdoutText: String { FileRead.decode(stdout) }
    /// Lines of stdout, trimmed and with empties dropped.
    var stdoutLines: [String] {
        stdoutText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// NUL-separated stdout fields, as produced by `git -z` flags.
    var stdoutNulFields: [String] {
        stdoutText.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }
}

/// Subprocess output, collected across threads.
///
/// `final class` with an internal lock rather than captured `var`s: a lock the
/// compiler cannot see does not make a captured variable safe to mutate from a
/// concurrent closure, and Swift 6 rejects it outright.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var overflowed = false
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Appends a chunk. Returns false when the stdout budget is exhausted and
    /// the caller should stop the process.
    func append(_ chunk: Data, toStandardOutput: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if toStandardOutput {
            guard out.count + chunk.count <= limit else {
                overflowed = true
                return false
            }
            out.append(chunk)
        } else if err.count < 64 * 1024 {
            // stderr is only ever shown in a message, so cap it hard and
            // independently of the stdout budget.
            err.append(chunk)
        }
        return true
    }

    func snapshot() -> (out: Data, err: Data, overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (out, err, overflowed)
    }
}

enum Subprocess {
    enum Failure: LocalizedError {
        case launchFailed(String)
        case timedOut(String, TimeInterval)
        case outputTooLarge(String, Int)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let tool):
                return "Could not run \(tool). Check that it is installed and on your PATH."
            case .timedOut(let tool, let seconds):
                return "\(tool) did not finish within \(Int(seconds))s and was stopped."
            case .outputTooLarge(let tool, let limit):
                return "\(tool) produced more than \(limit / 1024) KB of output and was stopped."
            }
        }
    }

    /// Runs a command with a wall-clock timeout and an output cap.
    ///
    /// Reading both pipes concurrently is not optional: a child that fills the
    /// stderr pipe blocks forever if the parent is only draining stdout, and
    /// `git` on a large repository will do exactly that.
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = ScanLimits.gitTimeout,
        maxOutputBytes: Int = ScanLimits.gitMaxOutputBytes
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        // Output shared between two reader threads and this one, behind its own
        // lock. A reference type rather than captured `var`s: the compiler
        // cannot see that a lock protects a captured variable, so mutating one
        // from a concurrent closure is a hard error under Swift 6 — and the
        // class makes the ownership obvious to a reader too.
        let buffer = OutputBuffer(limit: maxOutputBytes)

        let group = DispatchGroup()
        for (pipe, isStdout) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if !buffer.append(chunk, toStandardOutput: isStdout) {
                        process.terminate()
                        return
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(PosixPath.basename(executable))
        }

        if let inPipe, let stdin {
            // Write on a background thread: a payload larger than the pipe
            // buffer deadlocks if written inline while nobody is draining.
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let deadline = DispatchTime.now() + timeout
        var timedOut = false
        if process.isRunning {
            let waiter = DispatchGroup()
            waiter.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                waiter.leave()
            }
            if waiter.wait(timeout: deadline) == .timedOut {
                timedOut = true
                process.terminate()
                // Give it a moment to die politely, then stop waiting on it.
                _ = waiter.wait(timeout: .now() + 1)
            }
        }
        _ = group.wait(timeout: .now() + 2)

        let captured = buffer.snapshot()
        let tool = PosixPath.basename(executable)
        if timedOut { throw Failure.timedOut(tool, timeout) }
        if captured.overflowed { throw Failure.outputTooLarge(tool, maxOutputBytes) }

        return CommandResult(
            status: process.terminationStatus,
            stdout: captured.out,
            stderr: FileRead.decode(captured.err).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Resolves an executable name against PATH. Returns nil when absent, which
    /// is how provider detection tells "not installed" from "failed to run".
    static func which(_ name: String) -> String? {
        // Absolute paths bypass the search entirely.
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: - Atomic JSON persistence

enum JSONFile {
    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        // Sorted keys and pretty printing so the written graph diffs cleanly in
        // git — these files are meant to be committed alongside the code they
        // describe.
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Writes atomically via a temporary file plus rename, so an interrupted
    /// write leaves the previous file intact rather than a truncated one.
    static func write<T: Encodable>(_ value: T, to path: String, pretty: Bool = true) throws {
        let data = try encoder(pretty: pretty).encode(value)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Reads and decodes, returning nil for anything missing or malformed. A
    /// corrupt cache means "no cache", never a crash.
    static func read<T: Decodable>(_ type: T.Type, from path: String) -> T? {
        guard let data = ScanLimits.dataIfSmallEnough(path, limit: 256 * 1024 * 1024) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
