import CryptoKit
import Foundation

/// Discovers every file worth analyzing, and works out what the project *is*.
///
/// Ported from upstream's `scan-project.mjs`. Two details are load-bearing:
///
/// - `git ls-files -z -co --exclude-standard` is the fast path. The `-z` is not
///   cosmetic — without it git C-escapes any non-ASCII path, and those files
///   then fail to open.
/// - Line counts are the number of `0x0A` bytes, matching `wc -l`. Splitting on
///   newlines instead gives one more on a newline-terminated file, and the
///   batching heuristics downstream compare against upstream's numbers.
struct ProjectScanner: Sendable {
    let diagnostics: DiagnosticsCollector

    /// One file's scan record, including the hash used for the project digest.
    private struct Probe: Sendable {
        var file: ScannedFile
        var contentHash: Data
        var byteCount: Int
    }

    func scan(
        projectRoot: String,
        excludes: [String] = [],
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ScanResult {
        let root = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot

        let ignore = IgnoreFilter.layered(
            dataDirIgnore: FileRead.text(at: DataDirectory.resolve(root) + "/.understandignore"),
            rootIgnore: FileRead.text(at: root + "/.understandignore"),
            extraExcludes: excludes
        )
        let defaultsOnly = IgnoreFilter.defaultsOnly

        // Named, because a scan of a large tree is otherwise indistinguishable
        // from a hang: "Scanning files…" said nothing about which folder or how
        // far in. Pointing this at a home directory by mistake should look like
        // work in progress, not a frozen window.
        progress?("Enumerating \(PosixPath.basename(root))…")
        var candidates = gitTrackedFiles(root: root) ?? walk(root: root)
        progress?("Found \(candidates.count) files in \(PosixPath.basename(root)) — filtering…")

        // The analysis directory is our own output; including it would make the
        // graph describe itself.
        candidates.removeAll {
            $0.hasPrefix(".ua/") || $0.hasPrefix(".understand-anything/")
        }

        if candidates.count > ScanLimits.maxFilesPerProject {
            await diagnostics.add(
                .dropped, .truncated,
                "Project has \(candidates.count) files; analyzing the first \(ScanLimits.maxFilesPerProject)."
            )
            candidates = Array(candidates.prefix(ScanLimits.maxFilesPerProject))
        }

        var kept: [String] = []
        var filteredByUserRules = 0
        // Filtering a very large candidate set runs every ignore rule against
        // every path, which is the slowest part of a mistaken whole-disk scan.
        let reportEvery = max(1, candidates.count / 20)
        for (index, path) in candidates.enumerated() {
            if candidates.count > 20_000, index % reportEvery == 0 {
                progress?("Filtering \(index) of \(candidates.count) files…")
            }
            if ignore.isIgnored(path) {
                // Only the user's own rules are reported. Counting the built-in
                // exclusions too would make every project look aggressively
                // filtered and hide the number that actually reflects a choice.
                if !defaultsOnly.isIgnored(path) { filteredByUserRules += 1 }
                continue
            }
            kept.append(path)
        }
        kept = kept.sortedStable()

        progress?("Reading \(kept.count) files…")
        let probes = await probeAll(root: root, paths: kept)

        // Digest over every file's path and content hash, in sorted path order.
        // Seeded with a domain string so a digest can never collide with a
        // hash computed for some other purpose.
        var digest = SHA256()
        digest.update(data: Data("understand:scan-content:v1\0".utf8))
        for probe in probes {
            withUnsafeBytes(of: UInt32(probe.file.path.utf8.count).bigEndian) { digest.update(bufferPointer: $0) }
            withUnsafeBytes(of: UInt64(probe.byteCount).bigEndian) { digest.update(bufferPointer: $0) }
            digest.update(data: Data(probe.file.path.utf8))
            digest.update(data: probe.contentHash)
        }
        let contentDigest = digest.finalize().map { String(format: "%02x", $0) }.joined()

        let files = probes.map(\.file)
        let pathSet = Set(files.map(\.path))
        let manifests = readManifests(root: root, files: files)
        let frameworks = FrameworkDetector.detect(manifests: manifests)
        let languages = LanguageRegistry.primaryLanguages(in: files)
        let identity = projectIdentity(root: root, manifests: manifests)

        return ScanResult(
            projectName: identity.name,
            projectDescription: identity.description,
            files: files,
            languages: languages,
            frameworks: frameworks,
            totalFiles: files.count,
            filteredByIgnore: filteredByUserRules,
            estimatedComplexity: ProjectComplexity(fileCount: files.count),
            contentDigest: contentDigest,
            entryPoint: FrameworkDetector.entryPoint(in: pathSet, frameworks: frameworks)
        )
    }

    // MARK: - Enumeration

    /// Tracked and untracked-but-not-ignored files, straight from git. Returns
    /// nil when this is not a git repository or git is unavailable, which is a
    /// normal case rather than an error.
    private func gitTrackedFiles(root: String) -> [String]? {
        guard let git = Subprocess.which("git") else { return nil }
        guard let result = try? Subprocess.run(
            git, ["ls-files", "-z", "-co", "--exclude-standard"],
            cwd: root, timeout: ScanLimits.gitTimeout,
            maxOutputBytes: 256 * 1024 * 1024
        ), result.succeeded else { return nil }

        let paths = result.stdoutNulFields
        return paths.isEmpty ? nil : paths
    }

    /// Recursive walk for non-git projects.
    ///
    /// Uses the path-based enumerator rather than the URL-based one, because
    /// that yields paths already relative to the root. The URL variant returns
    /// *symlink-resolved absolute* paths, and on macOS `/tmp` is a symlink to
    /// `/private/tmp` while `resolvingSymlinksInPath()` leaves `/tmp` alone —
    /// so deriving a relative path by stripping the root prefix silently
    /// discards every file and reports the project as empty. Relative paths
    /// sidestep the mismatch entirely.
    private func walk(root: String) -> [String] {
        var out: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }

        while let relative = enumerator.nextObject() as? String {
            if out.count >= ScanLimits.maxFilesPerProject { break }
            if enumerator.level > ScanLimits.maxDirectoryDepth {
                enumerator.skipDescendants()
                continue
            }

            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            switch type {
            case .typeSymbolicLink:
                // Never followed: that is how a walk ends up in a loop or
                // outside the project entirely.
                enumerator.skipDescendants()
            case .typeDirectory:
                if IgnoreFilter.hardSkipDirectories.contains(PosixPath.basename(relative)) {
                    enumerator.skipDescendants()
                }
            case .typeRegular:
                out.append(PosixPath.normalize(relative))
            default:
                // Sockets, devices, pipes — real entries in some project trees,
                // and not things to read.
                break
            }
        }
        return out
    }

    // MARK: - Probing

    /// Reads every file once, in parallel, to get its line count and hash.
    ///
    /// Bounded to the machine's core count: the work is IO-bound but each task
    /// also hashes, and an unbounded group over 50 000 files would create
    /// 50 000 concurrent mappings.
    private func probeAll(root: String, paths: [String]) async -> [Probe] {
        let width = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunkSize = max(1, (paths.count + width - 1) / width)
        let chunks = stride(from: 0, to: paths.count, by: chunkSize).map {
            Array(paths[$0..<min($0 + chunkSize, paths.count)])
        }

        var results: [Int: [Probe]] = [:]
        await withTaskGroup(of: (Int, [Probe]).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    var out: [Probe] = []
                    out.reserveCapacity(chunk.count)
                    for path in chunk {
                        if let probe = Self.probe(root: root, path: path) { out.append(probe) }
                    }
                    return (index, out)
                }
            }
            for await (index, out) in group { results[index] = out }
        }

        // Reassemble in chunk order so the output stays in the sorted order the
        // digest depends on.
        return (0..<chunks.count).flatMap { results[$0] ?? [] }
    }

    private static func probe(root: String, path: String) -> Probe? {
        let absolute = root + "/" + path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir),
              !isDir.boolValue else { return nil }

        guard let data = ScanLimits.dataIfSmallEnough(absolute) else {
            // Too large to read, but still a real file: record it with a zero
            // line count rather than dropping it from the graph entirely.
            let attrs = try? FileManager.default.attributesOfItem(atPath: absolute)
            let size = (attrs?[.size] as? Int) ?? 0
            guard size > 0 else { return nil }
            return Probe(
                file: ScannedFile(path: path,
                                  language: LanguageRegistry.language(for: path),
                                  sizeLines: 0,
                                  fileCategory: LanguageRegistry.category(for: path)),
                contentHash: Data(SHA256.hash(data: Data("oversize:\(size)".utf8))),
                byteCount: size
            )
        }

        return Probe(
            file: ScannedFile(path: path,
                              language: LanguageRegistry.language(for: path),
                              sizeLines: FileRead.countNewlines(data),
                              fileCategory: LanguageRegistry.category(for: path)),
            contentHash: Data(SHA256.hash(data: data)),
            byteCount: data.count
        )
    }

    // MARK: - Project identity

    private func readManifests(root: String, files: [ScannedFile]) -> [String: String] {
        var out: [String: String] = [:]
        for file in files where FrameworkDetector.allManifestFilenames.contains(file.basename) {
            if let text = FileRead.text(at: root + "/" + file.path, limit: ScanLimits.maxHeaderBytes) {
                out[file.path] = text
            }
        }
        return out
    }

    /// Indefinite article for a project name, so the generated description
    /// does not read "A Understanley project".
    private static func article(for name: String) -> String {
        guard let first = name.first else { return "A" }
        return "AEIOUaeiou".contains(first) ? "An" : "A"
    }

    /// Name and description, preferring a package manifest over the directory
    /// name so the graph reads as the project rather than as a folder.
    private func projectIdentity(root: String, manifests: [String: String]) -> (name: String, description: String) {
        let fallbackName = PosixPath.basename(root)

        if let packageJSON = manifests["package.json"],
           let data = packageJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = (object["name"] as? String) ?? fallbackName
            let description = (object["description"] as? String) ?? ""
            return (name, description.isEmpty ? "\(Self.article(for: name)) \(name) project." : description)
        }

        for (path, contents) in manifests.sorted(by: { $0.key < $1.key }) {
            let base = PosixPath.basename(path)
            if base == "pyproject.toml" || base == "Cargo.toml" {
                let name = Self.tomlValue("name", in: contents) ?? fallbackName
                let description = Self.tomlValue("description", in: contents) ?? ""
                return (name, description.isEmpty ? "\(Self.article(for: name)) \(name) project." : description)
            }
            if base == "go.mod", let module = Self.goModuleName(in: contents) {
                let name = module.split(separator: "/").last.map(String.init) ?? module
                return (name, "Go module \(module).")
            }
        }

        return (fallbackName, "\(Self.article(for: fallbackName)) \(fallbackName) project.")
    }

    private static func tomlValue(_ key: String, in contents: String) -> String? {
        let pattern = Rx.compile("^\\s*\(key)\\s*=\\s*[\"']([^\"']+)[\"']",
                                 options: [.anchorsMatchLines])
        return pattern.group(1, in: contents)
    }

    private static func goModuleName(in contents: String) -> String? {
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("module ") else { continue }
            return String(trimmed.dropFirst("module ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

// MARK: - Data directory

/// Locates the project's analysis directory.
///
/// Upstream moved from `.understand-anything/` to `.ua/` but kept reading the
/// legacy directory when it already exists, so projects analyzed by the plugin
/// keep working with no migration. This port follows the same rule, which is
/// what lets the two tools share one project's data.
enum DataDirectory {
    static let legacyName = ".understand-anything"
    static let currentName = ".ua"

    static func resolve(_ projectRoot: String) -> String {
        let legacy = projectRoot + "/" + legacyName
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy, isDirectory: &isDir), isDir.boolValue {
            return legacy
        }
        return projectRoot + "/" + currentName
    }

    /// Records which build of the analyzer produced the cached graph.
    ///
    /// A sidecar rather than a field in `analysis-meta.json`, because that file
    /// is part of the upstream interop surface and this number means nothing
    /// outside this app.
    static func analyzerStampPath(_ projectRoot: String) -> String {
        resolve(projectRoot) + "/analyzer-version"
    }

    /// Per-file content and structure hashes from the last analysis, used to
    /// decide whether a change is worth re-analyzing for.
    static func fingerprintPath(_ projectRoot: String) -> String {
        resolve(projectRoot) + "/fingerprints.json"
    }

    static func graphPath(_ projectRoot: String) -> String {
        resolve(projectRoot) + "/knowledge-graph.json"
    }

    static func metaPath(_ projectRoot: String) -> String {
        resolve(projectRoot) + "/meta.json"
    }

    static func configPath(_ projectRoot: String) -> String {
        resolve(projectRoot) + "/config.json"
    }
}
