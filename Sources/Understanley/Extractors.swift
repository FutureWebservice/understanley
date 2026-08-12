import Foundation

/// Pulls structure out of one file.
///
/// Implementations are stateless values so they can be shared freely across
/// concurrent analysis tasks. Upstream uses tree-sitter here; this port uses
/// hand-written scanners over a comment- and string-blanked view of the source
/// (`SourceView`), which keeps the binary dependency-free. The accuracy gap is
/// narrower than it sounds: upstream's own extractors only walk direct children
/// of the parse-tree root, so nested declarations are outside their scope too.
protocol StructureExtractor: Sendable {
    /// Language ids this extractor claims, as produced by `LanguageRegistry`.
    var languages: [String] { get }
    /// Lexical syntax used to blank comments and strings before scanning.
    var syntax: CommentSyntax { get }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis
}

extension StructureExtractor {
    var syntax: CommentSyntax { .cStyle }
}

/// Language id → extractor. Built once; lookups are on the hot path.
struct ExtractorRegistry: Sendable {
    private let byLanguage: [String: any StructureExtractor]

    static let shared = ExtractorRegistry(extractors: [
        // Code
        JavaScriptExtractor(),
        PythonExtractor(),
        GoExtractor(),
        RustExtractor(),
        RubyExtractor(),
        SwiftExtractor(),
        JavaExtractor(),
        KotlinExtractor(),
        ScalaExtractor(),
        CSharpExtractor(),
        PHPExtractor(),
        CFamilyExtractor(),
        DartExtractor(),
        LuaExtractor(),
        ShellExtractor(),
        PowerShellExtractor(),
        // Non-code
        MarkdownParser(),
        YAMLParser(),
        JSONParser(),
        TOMLParser(),
        EnvParser(),
        DockerfileParser(),
        SQLParser(),
        GraphQLParser(),
        ProtobufParser(),
        TerraformParser(),
        MakefileParser(),
        HTMLCSSParser(),
    ])

    init(extractors: [any StructureExtractor]) {
        var map: [String: any StructureExtractor] = [:]
        // Later registrations win for a shared language id, matching upstream's
        // `PluginRegistry.register` — which is how the specialised non-code
        // parsers take precedence over the generic tree-sitter plugin.
        for extractor in extractors {
            for language in extractor.languages { map[language] = extractor }
        }
        byLanguage = map
    }

    func extractor(for language: String) -> (any StructureExtractor)? {
        byLanguage[language]
    }

    /// Analyzes one file. Returns nil when no extractor claims the language —
    /// the file still becomes a node, just without structure.
    func analyze(source: String, language: String, path: String) -> StructuralAnalysis? {
        guard let extractor = byLanguage[language] else { return nil }
        let view = SourceView(source: source, syntax: extractor.syntax)
        return extractor.extract(view, path: path)
    }
}

// MARK: - Shared call-graph extraction

enum CallGraph {
    /// Identifiers that look like calls but are control flow, casts or
    /// built-ins. Recording them would bury the real edges under noise present
    /// in every function.
    static let ignoredCallees: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "with", "do", "else",
        "elif", "except", "match", "case", "when", "unless", "until", "func",
        "function", "def", "class", "struct", "enum", "print", "println",
        "console", "typeof", "sizeof", "instanceof", "new", "delete", "throw",
        "await", "yield", "assert", "super", "self", "this", "String", "Int",
        "Number", "Boolean", "Array", "Object", "len", "range", "str", "int",
        "float", "bool", "list", "dict", "set", "tuple", "type", "isinstance",
        "require", "import", "export", "defer", "go", "select", "lock", "using",
    ]

    private static let callSite = Rx.compile(#"([A-Za-z_$][A-Za-z0-9_$]*)\s*\("#)

    /// Records which of `functions` calls which named callee, by scanning each
    /// function's own line span.
    ///
    /// Callee names are recorded unqualified — resolving them to a definition
    /// happens later in `GraphBuilder`, once every file's exports are known.
    /// A method call like `foo.bar()` records `bar`, which is what lets a
    /// cross-file call be matched against another file's exported symbol.
    static func extract(from view: SourceView, functions: [FunctionInfo]) -> [CallGraphEntry] {
        guard !functions.isEmpty else { return [] }
        var entries: [CallGraphEntry] = []
        // A caller/callee pair is recorded once, at its first occurrence — a
        // loop calling the same helper 40 times is still one relationship.
        var seen = Set<String>()

        for fn in functions {
            let start = max(0, fn.lineRange.start - 1)
            let end = min(view.text.count - 1, fn.lineRange.end - 1)
            guard start <= end else { continue }

            for index in start...end {
                let line = view.text[index]
                guard line.contains("(") else { continue }
                for groups in callSite.allGroups(in: line) {
                    guard let callee = groups[safe: 1] ?? nil, !callee.isEmpty else { continue }
                    if callee == fn.name { continue }
                    if ignoredCallees.contains(callee) { continue }
                    let key = "\(fn.name)\u{1}\(callee)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    entries.append(
                        CallGraphEntry(caller: fn.name, callee: callee, lineNumber: index + 1)
                    )
                }
            }
        }
        return entries
    }
}

extension Array {
    /// Bounds-checked subscript. Regex capture groups are frequently optional,
    /// and reaching past the group count is a crash waiting for the one input
    /// that does not match the way the pattern's author expected.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Array where Element == String? {
    /// Bounds-checked capture-group access, already flattened.
    ///
    /// A capture group is doubly optional — the group may not exist, and it may
    /// not have participated in the match. Callers want one answer, not two
    /// layers of `nil` to unwrap.
    subscript(group index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Shared building blocks

/// Helpers reused by several of the brace-language extractors.
enum ExtractHelpers {
    /// Collects method and property names from a class body.
    ///
    /// - Parameters:
    ///   - bodyRange: lines strictly inside the braces, zero-based.
    ///   - methodPattern: must capture the method name in group 1.
    ///   - propertyPattern: must capture the property name in group 1.
    /// Everything declared directly inside a type body.
    struct Members {
        var methods: [String] = []
        var properties: [String] = []
        /// One entry per method, with its real line span and parameters, named
        /// `Type.method`.
        var functions: [FunctionInfo] = []
    }

    /// Collects methods and properties from a type body.
    ///
    /// Methods come back as full `FunctionInfo` values, not just names, and
    /// that matters more than it looks. Upstream's tree-sitter extractors walk
    /// only the direct children of the parse-tree root, so in any language
    /// where functions live inside types — Swift, Java, C#, Kotlin — *no*
    /// function ever becomes its own node. The graph ends up with files and
    /// types and nothing in between, which is exactly the altitude a reader
    /// needs. Emitting methods as nodes is a deliberate improvement on
    /// upstream, and it is what makes the call graph meaningful in those
    /// languages at all.
    ///
    /// - Parameters:
    ///   - bodyRange: lines strictly inside the braces, zero-based.
    ///   - methodPattern: must capture the method name in group 1.
    ///   - propertyPattern: must capture the property name in group 1.
    ///   - typeName: qualifies method names so `User.save` and `Order.save`
    ///     stay distinct nodes.
    static func members(
        in view: SourceView,
        bodyRange: Range<Int>,
        headerDepth: Int,
        methodPattern: NSRegularExpression,
        propertyPattern: NSRegularExpression?,
        typeName: String
    ) -> Members {
        var out = Members()
        var seenMethods = Set<String>()
        var seenProperties = Set<String>()

        for index in bodyRange where index < view.text.count {
            // Only direct members: one level deeper than the type header.
            // Anything further in is a local declaration inside a method body.
            guard view.depthBefore[index] == headerDepth + 1 else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if let name = methodPattern.group(1, in: line), !name.isEmpty {
                guard seenMethods.insert(name).inserted else { continue }
                out.methods.append(name)

                let end = view.blockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                out.functions.append(
                    FunctionInfo(
                        name: "\(typeName).\(name)",
                        lineRange: LineRange(index + 1, max(index, end) + 1),
                        params: parameters(in: view, startingAt: index, fromOffset: offset,
                                           dropSelf: true),
                        returnType: nil
                    )
                )
                continue
            }
            if let propertyPattern,
               let name = propertyPattern.group(1, in: line), !name.isEmpty {
                if seenProperties.insert(name).inserted { out.properties.append(name) }
            }
        }
        return out
    }

    /// True when a name is exported by the "capitalised means public"
    /// convention (Go, and Elixir-style modules).
    static func isCapitalised(_ name: String) -> Bool {
        name.first.map { $0.isUppercase } ?? false
    }

    /// Parses a parameter list out of a declaration line.
    ///
    /// Signatures often wrap, so when the parentheses do not balance on the
    /// declaration line itself, following lines are appended until they do.
    /// Appending never invalidates `offset`, which is why the search restarts
    /// from the same position each round.
    static func parameters(
        in view: SourceView,
        startingAt line: Int,
        fromOffset offset: Int = 0,
        dropSelf: Bool = false,
        maxContinuationLines: Int = 8
    ) -> [String] {
        guard line < view.text.count else { return [] }
        var text = view.text[line]
        var consumed = 0

        while true {
            let start = text.index(text.startIndex, offsetBy: min(offset, text.count))
            if let group = ParamParser.balanced(text, from: start) {
                return ParamParser.names(from: group.inner, dropSelf: dropSelf)
            }
            consumed += 1
            guard consumed <= maxContinuationLines, line + consumed < view.text.count else {
                return []
            }
            text += " " + view.text[line + consumed]
        }
    }
}
