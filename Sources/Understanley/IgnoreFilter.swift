import Foundation

/// Gitignore-syntax path filter.
///
/// Ported from upstream's `ignore-filter.ts`, which delegates to the npm
/// `ignore` package. Two behaviours of that package are inherited deliberately
/// because output depends on them:
///
/// 1. **Matching is case-insensitive.** That is the npm package's default. It
///    means `**/*Test.swift` also excludes `Contest.swift` — surprising, but
///    changing it here would make this port exclude a different set of files
///    than upstream for the same `.understandignore`.
/// 2. **Last matching rule wins**, so a later `!pattern` re-includes something
///    an earlier rule excluded. Layer order is therefore load-bearing.
struct IgnoreFilter: Sendable {
    /// One compiled rule.
    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let isNegation: Bool
    }

    private let rules: [Rule]

    /// The built-in exclusions, applied before any user file. Order matches
    /// upstream exactly.
    static let defaultPatterns: [String] = [
        "node_modules/", ".git/", "vendor/", "venv/", ".venv/", "__pycache__/",
        "dist/", "build/", "out/", "coverage/", ".next/", ".cache/", ".turbo/",
        "target/", "obj/",
        "*.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "*.png", "*.jpg", "*.jpeg", "*.gif", "*.svg", "*.ico",
        "*.woff", "*.woff2", "*.ttf", "*.eot",
        "*.mp3", "*.mp4", "*.pdf", "*.zip", "*.tar", "*.gz",
        "*.min.js", "*.min.css", "*.map", "*.generated.*",
        ".idea/", ".vscode/",
        "LICENSE", ".gitignore", ".editorconfig", ".prettierrc", ".eslintrc*", "*.log",
    ]

    /// Directory names skipped before any pattern is consulted. Pruning these
    /// during the walk is what keeps a `node_modules` with 200k files from
    /// costing anything at all.
    static let hardSkipDirectories: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "__pycache__",
    ]

    init(patterns: [String]) {
        var compiled: [Rule] = []
        for raw in patterns {
            guard let rule = Self.compile(raw) else { continue }
            compiled.append(rule)
        }
        rules = compiled
    }

    /// Builds the four-layer filter upstream uses. Later layers can re-include
    /// what earlier ones excluded, via `!`.
    ///
    /// - Parameters:
    ///   - dataDirIgnore: contents of `<uaDir>/.understandignore`
    ///   - rootIgnore: contents of `<root>/.understandignore`
    ///   - extraExcludes: patterns from the user's exclude list, highest priority
    static func layered(
        dataDirIgnore: String? = nil,
        rootIgnore: String? = nil,
        extraExcludes: [String] = []
    ) -> IgnoreFilter {
        var patterns = defaultPatterns
        if let dataDirIgnore { patterns += lines(of: dataDirIgnore) }
        if let rootIgnore { patterns += lines(of: rootIgnore) }
        patterns += extraExcludes
        return IgnoreFilter(patterns: patterns)
    }

    /// Only the built-in rules. Used to work out how many files the *user's*
    /// rules excluded, which is what upstream reports as `filteredByIgnore` —
    /// reporting the defaults too would make every project look heavily
    /// filtered.
    static var defaultsOnly: IgnoreFilter { IgnoreFilter(patterns: defaultPatterns) }

    static func lines(of contents: String) -> [String] {
        contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// True when `path` (project-relative, POSIX) should be excluded.
    func isIgnored(_ path: String) -> Bool {
        let subject = PosixPath.normalize(path)
        guard !subject.isEmpty else { return false }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)

        // Last match wins, so scan backwards and stop at the first hit.
        for rule in rules.reversed() {
            if rule.regex.firstMatch(in: subject, options: [], range: range) != nil {
                return !rule.isNegation
            }
        }
        return false
    }

    // MARK: - Compilation

    private static func compile(_ rawPattern: String) -> Rule? {
        var pattern = rawPattern

        // Strip trailing whitespace unless the last space is backslash-escaped.
        while pattern.hasSuffix(" ") || pattern.hasSuffix("\t") {
            let withoutLast = String(pattern.dropLast())
            if withoutLast.hasSuffix("\\") { break }
            pattern = withoutLast
        }

        guard !pattern.isEmpty else { return nil }
        if pattern.hasPrefix("#") { return nil }
        // `\#` escapes a literal leading hash.
        if pattern.hasPrefix("\\#") { pattern = String(pattern.dropFirst()) }

        var isNegation = false
        if pattern.hasPrefix("!") {
            isNegation = true
            pattern = String(pattern.dropFirst())
        }
        guard !pattern.isEmpty else { return nil }

        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            pattern = String(pattern.dropLast())
        }
        guard !pattern.isEmpty else { return nil }

        // A slash at the start or in the middle anchors the pattern to the
        // project root. A *trailing* slash — already stripped above — does not,
        // which is why `dist/` still matches `packages/web/dist/main.js`.
        var anchored = false
        if pattern.hasPrefix("/") {
            anchored = true
            pattern = String(pattern.dropFirst())
        }
        if pattern.contains("/") { anchored = true }
        guard !pattern.isEmpty else { return nil }

        var body = globToRegex(pattern)

        // A directory rule must be followed by a path separator, so `dist/`
        // does not match a plain file named `dist`. Other rules match the entry
        // itself and everything beneath it.
        body += directoryOnly ? "/.*" : "(?:/.*)?"

        let prefix = anchored ? "^" : "(?:^|.*/)"
        guard let regex = try? NSRegularExpression(
            pattern: prefix + body + "$",
            options: [.caseInsensitive]
        ) else { return nil }

        return Rule(regex: regex, isNegation: isNegation)
    }

    /// Translates gitignore glob syntax to a regular expression.
    ///
    /// `*` and `?` stop at a path separator; `**` crosses them. Everything else
    /// is escaped so a pattern containing regex metacharacters — `.` is in
    /// nearly every pattern — is matched literally.
    private static func globToRegex(_ pattern: String) -> String {
        var out = ""
        let chars = Array(pattern)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                let isDoubleStar = i + 1 < chars.count && chars[i + 1] == "*"
                if isDoubleStar {
                    i += 2
                    // `**/` — zero or more leading directories.
                    if i < chars.count, chars[i] == "/" {
                        out += "(?:.*/)?"
                        i += 1
                    } else {
                        out += ".*"
                    }
                    continue
                }
                out += "[^/]*"
                i += 1

            case "?":
                out += "[^/]"
                i += 1

            case "[":
                // Character class, passed through with the negation form
                // translated. An unterminated `[` is treated as a literal.
                var j = i + 1
                if j < chars.count, chars[j] == "!" || chars[j] == "^" { j += 1 }
                if j < chars.count, chars[j] == "]" { j += 1 }
                while j < chars.count, chars[j] != "]" { j += 1 }
                if j < chars.count {
                    var cls = String(chars[(i + 1)...(j - 1)])
                    if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                    out += "[" + cls + "]"
                    i = j + 1
                } else {
                    out += "\\["
                    i += 1
                }

            case "\\":
                // Escape sequence: take the next character literally.
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 2
                } else {
                    out += "\\\\"
                    i += 1
                }

            case "/":
                out += "/"
                i += 1

            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
            }
        }
        return out
    }
}

// MARK: - Starter file generation

enum IgnoreGenerator {
    /// Test-file glob suggestions per language, emitted commented-out so the
    /// user opts in rather than silently losing their test files from the
    /// graph. Tests are genuinely useful nodes — they produce the `tested_by`
    /// edges — so excluding them is a choice, not a default.
    private static let testPatternsByLanguage: [(language: String, patterns: [String])] = [
        ("typescript", ["**/*.test.ts", "**/*.spec.ts", "**/*.test.tsx", "**/*.spec.tsx"]),
        ("javascript", ["**/*.test.js", "**/*.spec.js", "**/*.test.jsx", "**/*.spec.jsx"]),
        ("python", ["**/test_*.py", "**/*_test.py", "tests/"]),
        ("go", ["**/*_test.go"]),
        ("rust", ["**/tests/"]),
        ("java", ["**/*Test.java", "**/*Tests.java", "src/test/"]),
        ("kotlin", ["**/*Test.kt", "**/*Tests.kt", "src/test/"]),
        ("swift", ["**/*Tests.swift", "Tests/"]),
        ("ruby", ["**/*_spec.rb", "spec/"]),
        ("php", ["**/*Test.php", "tests/"]),
        ("csharp", ["**/*Test.cs", "**/*Tests.cs"]),
        ("scala", ["**/*Spec.scala", "**/*Suite.scala"]),
    ]

    /// Builds a starter `.understandignore` from the project's `.gitignore`
    /// plus language-appropriate test suggestions.
    ///
    /// Everything is commented out. The file is a menu, not a policy — upstream
    /// deliberately gates the first analysis on the user reviewing it, and this
    /// port keeps that gate.
    static func starterFile(gitignore: String?, languages: [String]) -> String {
        var out = """
        # .understandignore — files excluded from analysis.
        #
        # Same syntax as .gitignore. Matching is case-insensitive, and a later
        # rule wins over an earlier one, so `!pattern` re-includes.
        #
        # Built-in exclusions (node_modules, dist, images, lockfiles, …) are
        # always applied and do not need to be listed here.
        #
        # Everything below is commented out. Uncomment what you want excluded.

        """

        if let gitignore {
            let candidates = gitignore
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .filter { !IgnoreFilter.defaultPatterns.contains($0) }

            if !candidates.isEmpty {
                out += "\n# ── From your .gitignore ──────────────────────────────\n"
                for pattern in candidates.prefix(60) {
                    out += "# \(pattern)\n"
                }
            }
        }

        let present = Set(languages)
        let relevant = testPatternsByLanguage.filter { present.contains($0.language) }
        if !relevant.isEmpty {
            out += "\n# ── Test files ────────────────────────────────────────\n"
            out += "# Excluding tests makes the graph smaller but removes the\n"
            out += "# `tested_by` edges that show which code is covered.\n"
            for entry in relevant {
                out += "#\n# \(entry.language)\n"
                for pattern in entry.patterns {
                    out += "# \(pattern)\n"
                }
            }
        }

        return out
    }
}
