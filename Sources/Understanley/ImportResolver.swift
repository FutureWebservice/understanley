import Foundation

/// Turns an import statement into the project file it refers to.
///
/// Ported from upstream's `extract-import-map.mjs`, which is by some distance
/// the most detail-sensitive part of the pipeline: import edges are most of the
/// graph's structure, and a resolver that is subtly wrong produces a graph that
/// looks plausible and is not.
///
/// Only project-internal targets are returned. An import of `react` or
/// `net/http` resolves to nothing, which is correct — external packages are not
/// nodes.
struct ImportResolver: Sendable {
    private let root: String
    private let fileSet: Set<String>
    /// All project files, sorted, for prefix scans.
    private let allPaths: [String]

    // Per-language indices, built once.
    private let tsConfigs: [String: TSConfig]
    private let goModules: [String: String]
    private let psr4: [(prefix: String, targets: [String])]
    private let suffixIndex: [String: [String]]
    private let goFilesByDir: [String: [String]]

    struct TSConfig: Sendable {
        var baseURL: String
        /// Alias → targets, in declaration order. Order is load-bearing:
        /// upstream iterates the `paths` object in JSON key order and takes the
        /// first alias that matches, so a catch-all `"*"` declared before a
        /// specific `"@app/*"` shadows it.
        var paths: [(alias: String, targets: [String])]
    }

    init(root: String, files: [ScannedFile]) {
        self.root = root
        let paths = files.map(\.path)
        self.fileSet = Set(paths)
        self.allPaths = paths.sortedStable()

        var tsConfigs: [String: TSConfig] = [:]
        var goModules: [String: String] = [:]
        var psr4: [(String, [String])] = []
        var suffixIndex: [String: [String]] = [:]
        var goFilesByDir: [String: [String]] = [:]

        for path in allPaths {
            let base = PosixPath.basename(path)
            let dir = PosixPath.directory(of: path)

            switch base {
            case "tsconfig.json", "jsconfig.json":
                if let text = FileRead.text(at: root + "/" + path, limit: ScanLimits.maxHeaderBytes),
                   let config = Self.parseTSConfig(text) {
                    tsConfigs[dir] = config
                }
            case "go.mod":
                if let text = FileRead.text(at: root + "/" + path, limit: ScanLimits.maxHeaderBytes),
                   let module = Self.parseGoModule(text) {
                    goModules[dir] = module
                }
            case "composer.json":
                if let text = FileRead.text(at: root + "/" + path, limit: ScanLimits.maxHeaderBytes) {
                    psr4.append(contentsOf: Self.parsePSR4(text, configDir: dir))
                }
            default:
                break
            }

            // Basename index for languages that import by type name rather
            // than by path (Java, Kotlin, Scala, C#).
            suffixIndex[base, default: []].append(path)

            if PosixPath.fileExtension(path) == ".go" {
                goFilesByDir[dir, default: []].append(path)
            }
        }

        self.tsConfigs = tsConfigs
        self.goModules = goModules
        // Longest prefix first, so `App\Domain\` wins over `App\`.
        self.psr4 = psr4.sorted { $0.0.count > $1.0.count }
        self.suffixIndex = suffixIndex
        self.goFilesByDir = goFilesByDir
    }

    // MARK: - Entry point

    /// Every project file this import refers to. Usually zero or one; Python's
    /// `from . import a, b` and Go package imports can yield several.
    func resolve(_ importInfo: ImportInfo, from file: ScannedFile) -> [String] {
        let source = importInfo.source.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return [] }
        // Package/namespace declarations are recorded as imports so they reach
        // this point, but they declare rather than depend.
        guard !source.hasPrefix("package:") else { return [] }

        let dir = PosixPath.directory(of: file.path)

        switch file.language {
        case "typescript", "javascript", "vue", "svelte":
            return resolveTSJS(source, importerDir: dir).map { [$0] } ?? []
        case "python":
            return resolvePython(source, specifiers: importInfo.specifiers, importerDir: dir)
        case "go":
            return resolveGo(source, importerDir: dir)
        case "java", "kotlin", "scala":
            return resolveByTypeName(source, extensions: [".java", ".kt", ".kts", ".scala"])
        case "csharp":
            return resolveByTypeName(source, extensions: [".cs"])
        case "php":
            return resolvePHP(source, importerDir: dir)
        case "ruby":
            return resolveRelativeFile(source, importerDir: dir, extensions: [".rb"])
        case "rust":
            return resolveRust(source, importerPath: file.path)
        case "c", "cpp":
            return resolveRelativeFile(source, importerDir: dir,
                                       extensions: [".h", ".hpp", ".hxx", ".c", ".cpp", ".cc"])
        case "shell", "lua", "markdown", "html", "css", "sql", "protobuf", "json", "jsonc",
             "yaml", "dockerfile", "powershell":
            // Everything else that references another file does so by path.
            return resolveRelativeFile(source, importerDir: dir, extensions: [])
        default:
            return resolveRelativeFile(source, importerDir: dir, extensions: [])
        }
    }

    // MARK: - TypeScript / JavaScript

    /// Suffixes tried, in order, when a specifier has no extension.
    private static let tsExtensionProbes = [
        ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
        "/index.ts", "/index.tsx", "/index.js", "/index.jsx",
    ]

    /// NodeNext output extensions and the source extensions they may have come
    /// from. Order within each list matters — the first hit wins.
    private static let nodeNextRewrites: [(out: String, sources: [String])] = [
        (".js", [".ts", ".tsx", ".js", ".jsx"]),
        (".jsx", [".tsx", ".jsx"]),
        (".mjs", [".mts", ".mjs", ".ts"]),
        (".cjs", [".cts", ".cjs", ".ts"]),
    ]

    private func probeWithExtensions(_ basePath: String) -> String? {
        guard !basePath.isEmpty else { return nil }
        if fileSet.contains(basePath) { return basePath }

        // A NodeNext specifier names the *output* file (`./foo.js`) while the
        // project contains the *source* (`./foo.ts`). When the specifier
        // carries such an extension, only the corresponding source extensions
        // are valid — falling through to the generic probes would happily
        // resolve `./foo.js` to `foo.js.ts`, a file that does not exist in any
        // real project but that the probe list would otherwise construct.
        for rewrite in Self.nodeNextRewrites where basePath.hasSuffix(rewrite.out) {
            let stem = String(basePath.dropLast(rewrite.out.count))
            for ext in rewrite.sources {
                let candidate = stem + ext
                if fileSet.contains(candidate) { return candidate }
            }
            return nil
        }

        for ext in Self.tsExtensionProbes {
            let candidate = basePath + ext
            if fileSet.contains(candidate) { return candidate }
        }
        return nil
    }

    private func resolveTSJS(_ source: String, importerDir: String) -> String? {
        // Relative specifiers never consult tsconfig — they are resolved
        // against the importing file's own directory, full stop.
        if source.hasPrefix("./") || source.hasPrefix("../") {
            return probeWithExtensions(PosixPath.resolve(importerDir, source))
        }

        guard let configDir = nearestConfigDir(importerDir, in: tsConfigs),
              let config = tsConfigs[configDir], !config.paths.isEmpty else { return nil }

        for entry in config.paths {
            guard let wildcard = Self.matchTSAlias(entry.alias, source) else { continue }
            for target in entry.targets {
                let mapped = Self.applyTSAlias(target, wildcard: wildcard)
                let base = (config.baseURL == "." || config.baseURL.isEmpty)
                    ? "" : PosixPath.normalize(config.baseURL)
                let relativeToConfig = base.isEmpty ? mapped : PosixPath.join(base, mapped)
                // `resolve` in both cases, including at the project root.
                // `normalize` only drops *empty* segments — a "." segment
                // survives it — so the extremely common `"@/*": ["./*"]` mapping
                // produced "./app/adInit" and missed a file set that stores
                // "app/adInit". `resolve` collapses "." and ".." properly, and
                // handles an empty base directory the same way.
                let candidate = PosixPath.resolve(configDir, relativeToConfig)
                guard !candidate.isEmpty, !candidate.hasPrefix("..") else { continue }
                if let hit = probeWithExtensions(candidate) { return hit }
            }
        }
        return nil
    }

    /// Matches a tsconfig alias against a specifier. Returns the text captured
    /// by `*`, or `""` for an exact non-wildcard alias.
    static func matchTSAlias(_ alias: String, _ source: String) -> String? {
        guard let star = alias.firstIndex(of: "*") else {
            return alias == source ? "" : nil
        }
        let prefix = String(alias[alias.startIndex..<star])
        let suffix = String(alias[alias.index(after: star)...])
        guard source.hasPrefix(prefix), source.hasSuffix(suffix),
              source.count >= prefix.count + suffix.count else { return nil }
        let start = source.index(source.startIndex, offsetBy: prefix.count)
        let end = source.index(source.endIndex, offsetBy: -suffix.count)
        return String(source[start..<end])
    }

    static func applyTSAlias(_ target: String, wildcard: String) -> String {
        guard let star = target.firstIndex(of: "*") else { return target }
        return String(target[target.startIndex..<star]) + wildcard
            + String(target[target.index(after: star)...])
    }

    /// Deepest configuration directory that is a prefix of `startDir`.
    /// The project root (`""`) is a valid key and is tested last.
    private func nearestConfigDir<T>(_ startDir: String, in map: [String: T]) -> String? {
        guard !map.isEmpty else { return nil }
        var parts = startDir.split(separator: "/").map(String.init)
        while true {
            let candidate = parts.joined(separator: "/")
            if map[candidate] != nil { return candidate }
            if parts.isEmpty { return nil }
            parts.removeLast()
        }
    }

    // MARK: - Python

    private func resolvePython(_ source: String, specifiers: [String], importerDir: String) -> [String] {
        let dots = source.prefix(while: { $0 == "." }).count
        let tail = String(source.dropFirst(dots))
        let tailSegments = tail.split(separator: ".").map(String.init)

        var bases: [String] = []
        if dots > 0 {
            // `.` is the importer's own package, `..` its parent, and so on.
            var parts = importerDir.split(separator: "/").map(String.init)
            let dropLevels = dots - 1
            guard dropLevels <= parts.count else { return [] }
            parts.removeLast(dropLevels)
            bases = [parts.joined(separator: "/")]
        } else {
            // An absolute import is resolved from the project root and from the
            // usual source roots, since a package's directory is rarely the
            // repository root itself.
            bases = ["", "src", "lib", "app"]
        }

        var out: [String] = []
        for base in bases {
            let moduleDir = tailSegments.isEmpty
                ? base
                : PosixPath.join(base, tailSegments.joined(separator: "/"))

            if tailSegments.isEmpty {
                // `from . import a, b` — each specifier is a sibling module.
                for spec in specifiers where !spec.isEmpty && spec != "*" && !spec.contains(".") {
                    appendIfPresent(PosixPath.join(base, spec) + ".py", to: &out)
                    appendIfPresent(PosixPath.join(base, spec) + "/__init__.py", to: &out)
                }
                continue
            }

            let hadModule = appendIfPresent(moduleDir + ".py", to: &out)
                || appendIfPresent(moduleDir + "/__init__.py", to: &out)

            // `from pkg import thing` may import a submodule rather than a name
            // defined inside `pkg`.
            for spec in specifiers where !spec.isEmpty && spec != "*" {
                appendIfPresent(PosixPath.join(moduleDir, spec) + ".py", to: &out)
            }
            if hadModule, !out.isEmpty { break }
        }
        return out
    }

    @discardableResult
    private func appendIfPresent(_ path: String, to out: inout [String]) -> Bool {
        guard fileSet.contains(path), !out.contains(path) else { return false }
        out.append(path)
        return true
    }

    // MARK: - Go

    private func resolveGo(_ source: String, importerDir: String) -> [String] {
        guard let configDir = nearestConfigDir(importerDir, in: goModules),
              let module = goModules[configDir] else { return [] }
        guard source == module || source.hasPrefix(module + "/") else { return [] }

        let relative = source == module
            ? ""
            : String(source.dropFirst(module.count + 1))
        let dir = configDir.isEmpty ? relative : PosixPath.join(configDir, relative)

        // A Go import names a package, which is a directory of files. Test
        // files are excluded: importing a package does not depend on its tests.
        return (goFilesByDir[dir] ?? [])
            .filter { !$0.hasSuffix("_test.go") }
            .sortedStable()
    }

    // MARK: - JVM and .NET

    /// Resolves `com.example.Thing` by looking for a file named `Thing.<ext>`.
    ///
    /// Matching on the package path as well would be stricter, but real
    /// projects routinely have a source root (`src/main/java`) between the
    /// repository root and the package directory, so the basename plus a
    /// package-path check where possible is the pragmatic rule.
    private func resolveByTypeName(_ source: String, extensions: [String]) -> [String] {
        let segments = source.split(separator: ".").map(String.init)
        guard let typeName = segments.last, !typeName.isEmpty, typeName != "*" else { return [] }
        guard ExtractHelpers.isCapitalised(typeName) else { return [] }

        var candidates: [String] = []
        for ext in extensions {
            candidates.append(contentsOf: suffixIndex[typeName + ext] ?? [])
        }
        guard !candidates.isEmpty else { return [] }
        if candidates.count == 1 { return candidates }

        // Several files share the name — prefer one whose path also contains
        // the package directories.
        let packagePath = segments.dropLast().joined(separator: "/")
        if !packagePath.isEmpty {
            let matching = candidates.filter { $0.contains(packagePath) }
            if !matching.isEmpty { return matching.sortedStable() }
        }
        return candidates.sortedStable()
    }

    // MARK: - PHP

    private func resolvePHP(_ source: String, importerDir: String) -> [String] {
        // `use App\Service\Mailer` → PSR-4 prefix lookup.
        let normalized = source.replacingOccurrences(of: "/", with: "\\")
        for entry in psr4 where normalized.hasPrefix(entry.prefix) {
            let relative = String(normalized.dropFirst(entry.prefix.count))
                .replacingOccurrences(of: "\\", with: "/")
            for target in entry.targets {
                let candidate = PosixPath.join(target, relative) + ".php"
                if fileSet.contains(candidate) { return [candidate] }
            }
        }
        // `require 'path/to/file.php'`
        return resolveRelativeFile(source, importerDir: importerDir, extensions: [".php"])
    }

    // MARK: - Rust

    private func resolveRust(_ source: String, importerPath: String) -> [String] {
        // `mod foo;` — a sibling `foo.rs` or `foo/mod.rs`.
        let dir = PosixPath.directory(of: importerPath)
        let name = source.split(separator: ":").last.map(String.init) ?? source
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: " {}*;"))
        guard !clean.isEmpty else { return [] }

        var out: [String] = []
        appendIfPresent(PosixPath.join(dir, clean) + ".rs", to: &out)
        appendIfPresent(PosixPath.join(dir, clean) + "/mod.rs", to: &out)
        if out.isEmpty {
            // `use crate::a::b::Thing` — walk the module path from the crate root.
            let segments = source.components(separatedBy: "::")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " {}*;")) }
                .filter { !$0.isEmpty && $0 != "crate" && $0 != "self" && $0 != "super" }
            guard !segments.isEmpty else { return [] }
            for root in ["src", ""] {
                for depth in stride(from: segments.count, to: 0, by: -1) {
                    let modulePath = segments.prefix(depth).joined(separator: "/")
                    let base = PosixPath.join(root, modulePath)
                    if appendIfPresent(base + ".rs", to: &out) { return out }
                    if appendIfPresent(base + "/mod.rs", to: &out) { return out }
                }
            }
        }
        return out
    }

    // MARK: - Path-based

    /// Resolves a specifier that names a file path directly. Used by shell
    /// `source`, C `#include`, markdown links, CSS `@import` and similar.
    private func resolveRelativeFile(
        _ source: String, importerDir: String, extensions: [String]
    ) -> [String] {
        var specifier = source
        // Markdown links can carry a fragment or query.
        if let hash = specifier.firstIndex(of: "#") {
            specifier = String(specifier[specifier.startIndex..<hash])
        }
        if let query = specifier.firstIndex(of: "?") {
            specifier = String(specifier[specifier.startIndex..<query])
        }
        specifier = specifier.trimmingCharacters(in: .whitespaces)
        guard !specifier.isEmpty else { return [] }
        // A leading slash in a doc link or asset reference means "site root",
        // which for our purposes is the project root.
        let isRootRelative = specifier.hasPrefix("/")
        if isRootRelative { specifier = String(specifier.dropFirst()) }

        var candidates: [String] = []
        let resolved = isRootRelative
            ? PosixPath.normalize(specifier)
            : PosixPath.resolve(importerDir, specifier)
        guard !resolved.isEmpty else { return [] }

        candidates.append(resolved)
        for ext in extensions { candidates.append(resolved + ext) }
        // Also try from the project root, which is how most docs reference
        // files even when written from a nested directory.
        candidates.append(PosixPath.normalize(specifier))

        for candidate in candidates where fileSet.contains(candidate) {
            return [candidate]
        }
        return []
    }

    // MARK: - Config parsing

    /// Parses `tsconfig.json`, preserving the declaration order of `paths`.
    ///
    /// `JSONSerialization` produces an unordered dictionary, but alias order
    /// decides which mapping wins. The order is recovered by locating each key
    /// in the raw text — cheaper and far less brittle than writing a
    /// order-preserving JSON parser for one field.
    static func parseTSConfig(_ text: String) -> TSConfig? {
        let stripped = stripJSONComments(text)
        guard let data = stripped.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let options = root["compilerOptions"] as? [String: Any]
        else { return nil }

        let baseURL = (options["baseUrl"] as? String) ?? "."
        guard let rawPaths = options["paths"] as? [String: Any] else {
            return TSConfig(baseURL: baseURL, paths: [])
        }

        var ordered: [(alias: String, targets: [String], position: Int)] = []
        for (alias, value) in rawPaths {
            guard let targets = value as? [String] else { continue }
            let needle = "\"\(alias)\""
            let position = stripped.range(of: needle).map {
                stripped.distance(from: stripped.startIndex, to: $0.lowerBound)
            } ?? Int.max
            ordered.append((alias, targets, position))
        }
        ordered.sort { $0.position < $1.position }

        return TSConfig(baseURL: baseURL, paths: ordered.map { ($0.alias, $0.targets) })
    }

    /// Removes `//` and `/* */` comments and trailing commas so a `tsconfig`
    /// written in JSONC parses. String literals are preserved.
    static func stripJSONComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let ch = text[index]
            if inString {
                out.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
                index = text.index(after: index)
                continue
            }
            if ch == "\"" {
                inString = true
                out.append(ch)
                index = text.index(after: index)
                continue
            }
            if ch == "/", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                if next == "/" {
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if next == "*" {
                    index = text.index(index, offsetBy: 2)
                    while index < text.endIndex {
                        if text[index] == "*", text.index(after: index) < text.endIndex,
                           text[text.index(after: index)] == "/" {
                            index = text.index(index, offsetBy: 2)
                            break
                        }
                        index = text.index(after: index)
                    }
                    continue
                }
            }
            out.append(ch)
            index = text.index(after: index)
        }

        // Trailing commas before a closing bracket.
        return Rx.compile(#",(\s*[}\]])"#).stringByReplacingMatches(
            in: out, options: [],
            range: NSRange(out.startIndex..<out.endIndex, in: out),
            withTemplate: "$1"
        )
    }

    static func parseGoModule(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            var trimmed = String(line)
            if let comment = trimmed.range(of: "//") {
                trimmed = String(trimmed[trimmed.startIndex..<comment.lowerBound])
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("module ") else { continue }
            let module = String(trimmed.dropFirst("module ".count)).trimmingCharacters(in: .whitespaces)
            return module.isEmpty ? nil : module
        }
        return nil
    }

    static func parsePSR4(_ text: String, configDir: String) -> [(String, [String])] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let autoload = root["autoload"] as? [String: Any],
              let map = autoload["psr-4"] as? [String: Any]
        else { return [] }

        var out: [(String, [String])] = []
        for (prefix, value) in map {
            let rawTargets: [String]
            if let single = value as? String { rawTargets = [single] }
            else if let many = value as? [String] { rawTargets = many }
            else { continue }

            // `resolve`, not `normalize` — the same trap that killed every
            // JavaScript path alias lives here too. Composer autoload targets
            // are conventionally written "./src/", and `normalize` keeps the
            // "." segment, so the candidate became "./src/Service/Mailer.php"
            // against a file set holding "src/Service/Mailer.php".
            let targets = rawTargets.map { PosixPath.resolve(configDir, $0) }
                .filter { !$0.isEmpty }
            // A PSR-4 prefix always ends with a namespace separator.
            let normalizedPrefix = prefix.isEmpty || prefix.hasSuffix("\\") ? prefix : prefix + "\\"
            out.append((normalizedPrefix, targets))
        }
        return out
    }
}
