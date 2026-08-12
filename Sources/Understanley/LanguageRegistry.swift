import Foundation

/// Maps a file path to a language id and a processing category.
///
/// Ported from upstream's `scan-project.mjs`. The exact tables matter more than
/// they look: the language id selects which extractor runs, and the category
/// decides which node type a file becomes and whether a call graph is even
/// attempted. Getting `.h` wrong (it is `c`, not `cpp`) or letting
/// `docker-compose.yml` fall through to plain YAML changes the shape of the
/// resulting graph.
enum LanguageRegistry {
    // MARK: - Language

    /// Extension → language id. Extensions include the leading dot and are
    /// lowercase.
    static let languageByExtension: [String: String] = [
        // Code
        ".ts": "typescript", ".tsx": "typescript",
        ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript", ".cjs": "javascript",
        ".py": "python", ".pyi": "python",
        ".go": "go",
        ".rs": "rust",
        ".java": "java",
        ".kt": "kotlin", ".kts": "kotlin",
        ".scala": "scala", ".sc": "scala", ".sbt": "scala",
        ".cs": "csharp",
        ".swift": "swift",
        ".dart": "dart",
        ".lua": "lua",
        ".rb": "ruby", ".rake": "ruby",
        ".php": "php",
        // `.h` is C, not C++. Upstream routes both through the same tree-sitter
        // grammar but labels them differently, and the label is what the
        // framework detector and the UI show.
        ".c": "c", ".h": "c",
        ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp", ".hpp": "cpp", ".hxx": "cpp",
        ".vue": "vue",
        ".svelte": "svelte",
        ".sh": "shell", ".bash": "shell", ".zsh": "shell",
        ".ps1": "powershell", ".psm1": "powershell", ".psd1": "powershell",
        ".bat": "batch", ".cmd": "batch",
        // Markup
        ".html": "html", ".htm": "html",
        ".css": "css", ".scss": "css", ".sass": "css", ".less": "css",
        // Docs
        ".md": "markdown", ".mdx": "markdown", ".rst": "markdown",
        // Config
        ".yaml": "yaml", ".yml": "yaml",
        ".json": "json", ".jsonc": "jsonc",
        ".toml": "toml",
        ".xml": "xml", ".xsl": "xml", ".xsd": "xml", ".plist": "xml",
        ".cfg": "config", ".ini": "config", ".env": "config",
        ".properties": "properties",
        ".csproj": "csproj", ".sln": "sln",
        ".gradle": "gradle",
        ".mod": "mod", ".sum": "sum",
        // Data
        ".sql": "sql",
        ".graphql": "graphql", ".gql": "graphql",
        ".proto": "protobuf",
        ".prisma": "prisma",
        ".csv": "csv", ".tsv": "csv",
        // Infra
        ".tf": "terraform", ".tfvars": "terraform",
    ]

    /// Exact filename → language id. Case-sensitive, matching upstream.
    static let languageByFilename: [String: String] = [
        "Dockerfile": "dockerfile",
        "Makefile": "makefile",
        "GNUmakefile": "makefile",
        "makefile": "makefile",
        "Jenkinsfile": "jenkinsfile",
        "Procfile": "procfile",
        "Vagrantfile": "vagrantfile",
    ]

    /// For a dotfile, the first dot-prefixed alphanumeric run, lowercased —
    /// `.env.local` → `.env`, `.bashrc` → `.bashrc`. Returns nil for anything
    /// not starting with a dot, so `package.json` is unaffected.
    static func dotfileKey(_ basename: String) -> String? {
        guard basename.hasPrefix(".") else { return nil }
        var key = "."
        for ch in basename.dropFirst() {
            guard ch.isLetter || ch.isNumber else { break }
            key.append(ch)
        }
        return key.count > 1 ? key.lowercased() : nil
    }

    /// Resolves a language id. Never returns nil: an unrecognised extension
    /// becomes the extension itself (`.foo` → `foo`), so unusual file types
    /// still group sensibly in the UI instead of collapsing into one bucket.
    static func language(for path: String) -> String {
        let base = PosixPath.basename(path)

        // 1. Dockerfile and its variants (Dockerfile.dev, Dockerfile.prod…).
        if base == "Dockerfile" || base.hasPrefix("Dockerfile.") { return "dockerfile" }

        // 2. Dotfiles resolve on their leading key, so `.env.production` is
        //    still an env file.
        if let key = dotfileKey(base), let lang = languageByExtension[key] { return lang }

        // 3. Extension.
        let ext = PosixPath.fileExtension(path)
        if !ext.isEmpty {
            return languageByExtension[ext] ?? String(ext.dropFirst())
        }

        // 4. Extensionless well-known filenames.
        if let lang = languageByFilename[base] { return lang }

        return "unknown"
    }

    // MARK: - Category

    /// Filenames that are infrastructure regardless of extension.
    static let infraFilenames: Set<String> = [
        "Dockerfile", ".dockerignore", "Makefile", "GNUmakefile", "makefile",
        "Jenkinsfile", "Procfile", "Vagrantfile", ".gitlab-ci.yml",
    ]

    static let categoryByExtension: [String: FileCategory] = [
        ".md": .docs, ".mdx": .docs, ".rst": .docs, ".txt": .docs, ".text": .docs,

        ".yaml": .config, ".yml": .config, ".json": .config, ".jsonc": .config,
        ".toml": .config, ".xml": .config, ".xsl": .config, ".xsd": .config,
        ".plist": .config, ".cfg": .config, ".ini": .config, ".env": .config,
        ".properties": .config, ".csproj": .config, ".sln": .config,
        ".mod": .config, ".sum": .config, ".gradle": .config, ".sbt": .config,

        ".tf": .infra, ".tfvars": .infra,

        ".sql": .data, ".graphql": .data, ".gql": .data, ".proto": .data,
        ".prisma": .data, ".csv": .data, ".tsv": .data,

        ".sh": .script, ".bash": .script, ".zsh": .script,
        ".ps1": .script, ".psm1": .script, ".psd1": .script,
        ".bat": .script, ".cmd": .script,

        ".html": .markup, ".htm": .markup,
        ".css": .markup, ".scss": .markup, ".sass": .markup, ".less": .markup,
    ]

    /// Assigns a processing category, in upstream's exact priority order.
    ///
    /// The ordering is the whole point — path-based infrastructure rules must
    /// beat the extension table, or every GitHub Actions workflow would be
    /// filed as ordinary YAML config and lose its pipeline node type.
    static func category(for path: String) -> FileCategory {
        let posix = PosixPath.normalize(path)
        let base = PosixPath.basename(posix)

        // 1. LICENSE has no extension and is not documentation in the sense
        //    that matters here; upstream keeps it as `code` so it lands in the
        //    graph as an ordinary file node.
        if base == "LICENSE" { return .code }

        // 2–5. Infrastructure by filename.
        if infraFilenames.contains(base) { return .infra }
        if base == "Dockerfile" || base.hasPrefix("Dockerfile.") { return .infra }
        if base.hasPrefix("docker-compose.") { return .infra }
        if base == "compose.yml" || base == "compose.yaml" { return .infra }

        // 6–9. Infrastructure by location.
        if posix.hasPrefix(".github/workflows/") { return .infra }
        if posix.hasPrefix(".circleci/") { return .infra }
        if containsSegment(posix, "k8s") || containsSegment(posix, "kubernetes") { return .infra }
        let lowerBase = base.lowercased()
        if lowerBase.hasSuffix(".k8s.yml") || lowerBase.hasSuffix(".k8s.yaml") { return .infra }

        // 10. Extension table.
        if let category = categoryByExtension[PosixPath.fileExtension(posix)] { return category }

        // 11. Dotfile key, so `.env.local` is config like `.env`.
        if let key = dotfileKey(base), let category = categoryByExtension[key] { return category }

        // 12. Everything else is treated as code and given to an extractor.
        return .code
    }

    /// True when `segment` appears as a whole path component.
    private static func containsSegment(_ posix: String, _ segment: String) -> Bool {
        posix.split(separator: "/").dropLast().contains { $0 == Substring(segment) }
    }

    // MARK: - Display

    /// Languages worth listing in the project summary. Config and data formats
    /// are real languages to the parser but noise in "this is a TypeScript
    /// project", so they are excluded from the headline list.
    private static let notablyProgramming: Set<String> = [
        "typescript", "javascript", "python", "go", "rust", "java", "kotlin",
        "scala", "csharp", "swift", "dart", "lua", "ruby", "php", "c", "cpp",
        "vue", "svelte", "shell", "powershell",
    ]

    /// The project's primary languages, most files first. Ties break
    /// alphabetically so the list is stable across runs.
    static func primaryLanguages(in files: [ScannedFile], limit: Int = 8) -> [String] {
        var counts: [String: Int] = [:]
        for file in files where notablyProgramming.contains(file.language) {
            counts[file.language, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
