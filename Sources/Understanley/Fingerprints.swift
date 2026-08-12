import Foundation

/// Tracks what changed between analyses, so a re-run costs what the change
/// costs rather than what the project costs.
///
/// Ported from upstream's `fingerprint.ts` and `change-classifier.ts`. The
/// distinction that matters is **cosmetic versus structural**: reformatting a
/// file, editing a comment or changing a function's internals leaves the graph
/// identical, because the graph records signatures and relationships, not
/// bodies. Only a change to what a file *declares* or *imports* can move an
/// edge. Getting that distinction right is what makes re-analysis nearly free
/// on a normal edit.
enum Fingerprints {
    /// A file's structural signature, ignoring everything the graph does not
    /// depend on.
    struct FileFingerprint: Codable, Sendable {
        var contentHash: String
        var functions: [Signature]
        var classes: [TypeSignature]
        var imports: [String]
        var exports: [String]
        /// False when no extractor claimed the file. Compared conservatively:
        /// with no structure to compare, any content change is structural.
        var hasStructuralAnalysis: Bool

        struct Signature: Codable, Sendable {
            var name: String
            var params: [String]
            var returnType: String?
            var exported: Bool
            var lineCount: Int
        }

        struct TypeSignature: Codable, Sendable {
            var name: String
            var methods: [String]
            var properties: [String]
            var exported: Bool
            var lineCount: Int
        }
    }

    struct Store: Codable, Sendable {
        var version: String
        var gitCommitHash: String
        var generatedAt: String
        var files: [String: FileFingerprint]

        static let currentVersion = "1.0.0"
    }

    /// How a single file changed.
    enum Change: String, Sendable {
        /// Byte-identical.
        case none
        /// Content changed, but nothing the graph records.
        case cosmetic
        /// Something the graph records changed.
        case structural
    }

    /// What a re-analysis needs to do.
    enum UpdateKind: String, Sendable {
        /// Nothing structural moved; the existing graph still holds.
        case skip
        /// Re-analyze the changed files only.
        case partial
        /// Re-analyze changed files and recompute layers and the tour, because
        /// the shape of the project moved.
        case architecture
        /// Start over.
        case full

        var rerunsArchitecture: Bool { self == .architecture || self == .full }
    }

    struct ChangeSet: Sendable {
        var unchanged: [String] = []
        var cosmetic: [String] = []
        var structural: [String] = []
        var added: [String] = []
        var deleted: [String] = []

        /// Files whose analysis must be redone. Deletions are handled by
        /// pruning, not by re-reading a file that is gone.
        var filesToReanalyze: [String] { structural + added }

        var structuralCount: Int { structural.count + added.count + deleted.count }
    }

    // MARK: - Building

    static func fingerprint(source: String, analysis: StructuralAnalysis?) -> FileFingerprint {
        let hash = Hash.sha256Hex(source)
        guard let analysis else {
            return FileFingerprint(contentHash: hash, functions: [], classes: [],
                                   imports: [], exports: [], hasStructuralAnalysis: false)
        }
        let exported = analysis.exportedNames
        return FileFingerprint(
            contentHash: hash,
            functions: analysis.functions.map {
                .init(name: $0.name, params: $0.params, returnType: $0.returnType,
                      exported: exported.contains($0.name), lineCount: $0.lineRange.lineCount)
            },
            classes: analysis.classes.map {
                .init(name: $0.name, methods: $0.methods.sorted(), properties: $0.properties.sorted(),
                      exported: exported.contains($0.name), lineCount: $0.lineRange.lineCount)
            },
            // Sorted so a reordered import block is cosmetic, which it is.
            imports: analysis.imports
                .map { "\($0.source):\($0.specifiers.sorted().joined(separator: ","))" }
                .sorted(),
            exports: analysis.exports.map(\.name).sorted(),
            hasStructuralAnalysis: true
        )
    }

    static func buildStore(
        projectRoot: String, files: [ScannedFile], gitCommitHash: String
    ) -> Store {
        var out: [String: FileFingerprint] = [:]
        for file in files {
            guard let source = FileRead.text(at: projectRoot + "/" + file.path) else { continue }
            let analysis = ExtractorRegistry.shared.analyze(
                source: source, language: file.language, path: file.path
            )
            out[file.path] = fingerprint(source: source, analysis: analysis)
        }
        return Store(
            version: Store.currentVersion,
            gitCommitHash: gitCommitHash,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            files: out
        )
    }

    // MARK: - Comparing

    static func compare(_ old: FileFingerprint, _ new: FileFingerprint) -> Change {
        if old.contentHash == new.contentHash { return .none }
        // With no structure on either side there is nothing to compare, so the
        // safe answer is the expensive one.
        if !old.hasStructuralAnalysis || !new.hasStructuralAnalysis { return .structural }

        if old.imports != new.imports { return .structural }
        if old.exports != new.exports { return .structural }

        let oldFunctions = Dictionary(old.functions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newFunctions = Dictionary(new.functions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        if Set(oldFunctions.keys) != Set(newFunctions.keys) { return .structural }
        for (name, oldFn) in oldFunctions {
            guard let newFn = newFunctions[name] else { return .structural }
            if oldFn.params != newFn.params { return .structural }
            if oldFn.returnType != newFn.returnType { return .structural }
            if oldFn.exported != newFn.exported { return .structural }
            // A function that doubled or halved in size has changed enough that
            // its summary is probably wrong, even if its signature has not.
            if oldFn.lineCount > 0 {
                let ratio = Double(newFn.lineCount) / Double(oldFn.lineCount)
                if ratio > 1.5 || ratio < 0.5 { return .structural }
            }
        }

        let oldTypes = Dictionary(old.classes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let newTypes = Dictionary(new.classes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        if Set(oldTypes.keys) != Set(newTypes.keys) { return .structural }
        for (name, oldType) in oldTypes {
            guard let newType = newTypes[name] else { return .structural }
            if oldType.methods != newType.methods { return .structural }
            if oldType.properties != newType.properties { return .structural }
            if oldType.exported != newType.exported { return .structural }
        }

        return .cosmetic
    }

    /// Classifies every changed path against a stored baseline.
    static func analyzeChanges(
        projectRoot: String, store: Store, currentFiles: [ScannedFile]
    ) -> ChangeSet {
        var out = ChangeSet()
        let currentByPath = Dictionary(currentFiles.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        for (path, old) in store.files.sorted(by: { compareUTF16($0.key, $1.key) == .orderedAscending }) {
            guard let file = currentByPath[path] else {
                out.deleted.append(path)
                continue
            }
            guard let source = FileRead.text(at: projectRoot + "/" + path) else {
                out.deleted.append(path)
                continue
            }
            // Hash first: it settles the overwhelmingly common case without
            // parsing anything.
            if Hash.sha256Hex(source) == old.contentHash {
                out.unchanged.append(path)
                continue
            }
            let analysis = ExtractorRegistry.shared.analyze(
                source: source, language: file.language, path: path
            )
            switch compare(old, fingerprint(source: source, analysis: analysis)) {
            case .none: out.unchanged.append(path)
            case .cosmetic: out.cosmetic.append(path)
            case .structural: out.structural.append(path)
            }
        }

        for file in currentFiles where store.files[file.path] == nil {
            out.added.append(file.path)
        }
        return out
    }

    /// Decides how much of the pipeline to re-run.
    ///
    /// Thresholds are upstream's: more than 30 changed files, or more than half
    /// the project, means a full rebuild is cheaper than reconciling; more than
    /// 10, or a change to the set of top-level directories, means the
    /// architecture moved and layers must be recomputed.
    static func classify(_ changes: ChangeSet, totalFilesInGraph: Int) -> UpdateKind {
        let count = changes.structuralCount
        if count == 0 { return .skip }
        if count > 30 { return .full }
        if totalFilesInGraph > 0, Double(count) / Double(totalFilesInGraph) > 0.5 { return .full }
        if count > 10 { return .architecture }
        if introducesNewTopLevelDirectory(changes) { return .architecture }
        return .partial
    }

    /// True when a file appeared in or vanished from a top-level directory the
    /// graph has not seen — that is a change to the project's shape, not just
    /// its contents.
    private static func introducesNewTopLevelDirectory(_ changes: ChangeSet) -> Bool {
        let known = Set((changes.unchanged + changes.cosmetic + changes.structural)
            .compactMap(PosixPath.topDirectory))
        for path in changes.added + changes.deleted {
            guard let top = PosixPath.topDirectory(path) else { continue }
            if !known.contains(top) { return true }
        }
        return false
    }

    // MARK: - Persistence

    static func path(projectRoot: String) -> String {
        DataDirectory.resolve(projectRoot) + "/fingerprints.json"
    }

    static func load(projectRoot: String) -> Store? {
        JSONFile.read(Store.self, from: path(projectRoot: projectRoot))
    }

    static func save(_ store: Store, projectRoot: String) throws {
        // Compact: this file is machine-only and grows with the project.
        try JSONFile.write(store, to: path(projectRoot: projectRoot), pretty: false)
    }
}
