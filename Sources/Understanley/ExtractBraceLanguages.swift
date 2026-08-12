import Foundation

/// How a language decides what is visible outside its file.
enum ExportRule: Sendable {
    /// A leading modifier keyword makes it public (`public`, `pub`, `open`).
    case modifier(Set<String>)
    /// A capitalised identifier is public (Go).
    case capitalised
    /// Everything top-level is reachable (Python, Lua, shell).
    case all
}

/// Declarative description of a curly-brace language.
///
/// The brace languages differ far less than their communities suggest — all of
/// them spell a declaration as `modifiers keyword Name(params) { body }`. One
/// driver over a per-language pattern set gives eleven working extractors
/// without eleven near-identical files, and every difference that *does* matter
/// stays visible as data rather than buried in a subclass.
struct BraceLanguageSpec: Sendable {
    var languages: [String]
    var syntax: CommentSyntax = .cStyle
    /// Each must capture the declaration name in group 1.
    var functionPatterns: [NSRegularExpression]
    /// Classes, structs, interfaces, protocols, enums, traits — anything that
    /// becomes a `class` node. Name in group 1.
    var typePatterns: [NSRegularExpression]
    /// Import/include/use statements. Source in group 1.
    var importPatterns: [NSRegularExpression]
    /// Members of a type body. Name in group 1.
    var methodPattern: NSRegularExpression
    var propertyPattern: NSRegularExpression?
    var exportRule: ExportRule
    /// Namespace or package declaration, recorded as an import so the graph can
    /// resolve fully-qualified references later. Name in group 1.
    var packagePattern: NSRegularExpression?
    /// True when a type body's members sit one brace deeper than the header.
    /// False for languages where the header itself opens no brace (C typedefs).
    var membersNestOneLevel: Bool = true
}

/// Drives extraction for every language described by a `BraceLanguageSpec`.
struct BraceLanguageExtractor: StructureExtractor {
    let spec: BraceLanguageSpec

    var languages: [String] { spec.languages }
    var syntax: CommentSyntax { spec.syntax }

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        var exported = Set<String>()

        for index in view.topLevelLines {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            // ── Imports ──
            var matchedImport = false
            for pattern in spec.importPatterns {
                guard let groups = pattern.firstGroups(in: line),
                      let source = groups[group: 1], !source.isEmpty else { continue }
                analysis.imports.append(
                    ImportInfo(source: source,
                               specifiers: Self.specifiers(from: source),
                               lineNumber: index + 1)
                )
                matchedImport = true
                break
            }
            if matchedImport { continue }

            if let packagePattern = spec.packagePattern,
               let groups = packagePattern.firstGroups(in: line),
               let name = groups[group: 1] {
                // Recorded with an explicit marker so the import resolver can
                // tell a package declaration from a real dependency.
                analysis.imports.append(
                    ImportInfo(source: "package:" + name, specifiers: [], lineNumber: index + 1)
                )
                continue
            }

            // ── Types ──
            var matchedType = false
            for pattern in spec.typePatterns {
                guard let groups = pattern.firstGroups(in: line),
                      let name = groups[group: 1], !name.isEmpty else { continue }
                let end = view.blockEnd(from: index)
                let body = (index + 1)..<max(index + 1, end)
                let members = ExtractHelpers.members(
                    in: view, bodyRange: body,
                    headerDepth: spec.membersNestOneLevel ? 0 : -1,
                    methodPattern: spec.methodPattern,
                    propertyPattern: spec.propertyPattern,
                    typeName: name
                )
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: members.methods, properties: members.properties)
                )
                analysis.functions.append(contentsOf: members.functions)
                if isExported(line, name: name), exported.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                matchedType = true
                break
            }
            if matchedType { continue }

            // ── Functions ──
            for pattern in spec.functionPatterns {
                guard let groups = pattern.firstGroups(in: line),
                      let name = groups[group: 1], !name.isEmpty else { continue }
                let end = line.contains("{") || line.hasSuffix("=")
                    ? view.blockEnd(from: index)
                    : view.blockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: ExtractHelpers.parameters(
                                     in: view, startingAt: index, fromOffset: offset),
                                 returnType: nil)
                )
                if isExported(line, name: name), exported.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                break
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    private func isExported(_ line: String, name: String) -> Bool {
        switch spec.exportRule {
        case .all:
            return true
        case .capitalised:
            return ExtractHelpers.isCapitalised(name)
        case .modifier(let keywords):
            // The modifier must lead the declaration, so a parameter named
            // `public` or a comment mentioning it cannot promote a private
            // declaration.
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            for word in words {
                if keywords.contains(word) { return true }
                // Stop at the first non-modifier word: past that point we are
                // into the declaration itself.
                if !Self.leadingNoise.contains(word) { return false }
            }
            return false
        }
    }

    /// Words that may appear before a visibility modifier without ending the
    /// modifier run.
    private static let leadingNoise: Set<String> = [
        "@", "final", "static", "abstract", "sealed", "data", "inline", "suspend",
        "override", "async", "unsafe", "extern", "const", "readonly", "partial",
        "virtual", "explicit", "implicit", "operator", "case", "indirect",
        "@objc", "@inlinable", "@discardableResult", "@MainActor", "@available",
    ]

    /// Last path component of an import source, used as its bound name.
    private static func specifiers(from source: String) -> [String] {
        let cleaned = source.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'<>;"))
        let separators: [Character] = ["/", ".", ":", "\\"]
        var last = cleaned
        for sep in separators {
            if let idx = last.lastIndex(of: sep) {
                last = String(last[last.index(after: idx)...])
            }
        }
        return last.isEmpty ? [] : [last]
    }
}

// MARK: - Language specifications

extension BraceLanguageSpec {
    static let java = BraceLanguageSpec(
        languages: ["java"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>]+>\s*)?[\w$.<>\[\],?\s]+?\s+([A-Za-z_$][\w$]*)\s*\("#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|static|final|abstract|sealed|non-sealed)\s+)*(?:class|interface|enum|record|@interface)\s+([A-Za-z_$][\w$]*)"#
        )],
        importPatterns: [Rx.compile(#"^import\s+(?:static\s+)?([\w$.]+(?:\.\*)?)\s*;"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|protected|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>]+>\s*)?[\w$.<>\[\],?\s]+?\s+([A-Za-z_$][\w$]*)\s*\("#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:public|private|protected|static|final|volatile|transient)\s+)+[\w$.<>\[\],?]+\s+([A-Za-z_$][\w$]*)\s*[=;]"#
        ),
        exportRule: .modifier(["public", "protected"]),
        packagePattern: Rx.compile(#"^package\s+([\w$.]+)\s*;"#)
    )

    static let kotlin = BraceLanguageSpec(
        languages: ["kotlin"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|internal|open|override|abstract|final|inline|suspend|operator|infix|tailrec|external|expect|actual)\s+)*fun\s+(?:<[^>]+>\s*)?(?:[\w.<>]+\.)?([A-Za-z_][\w]*)\s*\("#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|internal|open|abstract|sealed|data|value|inner|enum|annotation|expect|actual)\s+)*(?:class|interface|object)\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [Rx.compile(#"^import\s+([\w.]+(?:\.\*)?)"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|protected|internal|open|override|abstract|final|inline|suspend|operator)\s+)*fun\s+(?:<[^>]+>\s*)?([A-Za-z_][\w]*)\s*\("#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:public|private|protected|internal|open|override|const|lateinit)\s+)*va[lr]\s+([A-Za-z_][\w]*)"#
        ),
        // Kotlin declarations are public unless marked otherwise, so absence of
        // a modifier means exported.
        exportRule: .all,
        packagePattern: Rx.compile(#"^package\s+([\w.]+)"#)
    )

    static let scala = BraceLanguageSpec(
        languages: ["scala"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:private|protected|final|override|implicit|lazy|inline)\s+)*def\s+([A-Za-z_][\w]*)"#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:private|protected|final|sealed|abstract|implicit|case)\s+)*(?:class|trait|object|enum)\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [Rx.compile(#"^import\s+([\w.]+(?:\.[_{][^\n]*)?)"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:private|protected|final|override|implicit|lazy)\s+)*def\s+([A-Za-z_][\w]*)"#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:private|protected|final|override|implicit|lazy)\s+)*va[lr]\s+([A-Za-z_][\w]*)"#
        ),
        exportRule: .all,
        packagePattern: Rx.compile(#"^package\s+([\w.]+)"#)
    )

    static let csharp = BraceLanguageSpec(
        languages: ["csharp"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|internal|static|virtual|override|abstract|sealed|async|extern|partial|new|unsafe)\s+)+(?:[\w<>\[\],?.]+\s+)?([A-Za-z_][\w]*)\s*(?:<[^>]*>)?\s*\("#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|internal|static|abstract|sealed|partial|readonly|ref)\s+)*(?:class|interface|struct|enum|record)\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [Rx.compile(#"^using\s+(?:static\s+)?([\w.]+)\s*;"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|protected|internal|static|virtual|override|abstract|sealed|async|extern|partial|new)\s+)+(?:[\w<>\[\],?.]+\s+)?([A-Za-z_][\w]*)\s*(?:<[^>]*>)?\s*\("#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:public|private|protected|internal|static|readonly|const|virtual|override)\s+)+[\w<>\[\],?.]+\s+([A-Za-z_][\w]*)\s*(?:[{=;])"#
        ),
        exportRule: .modifier(["public", "protected", "internal"]),
        packagePattern: Rx.compile(#"^namespace\s+([\w.]+)"#)
    )

    static let swift = BraceLanguageSpec(
        languages: ["swift"],
        syntax: .swiftStyle,
        functionPatterns: [Rx.compile(
            #"^(?:(?:public|private|internal|fileprivate|open|static|class|final|override|mutating|nonmutating|required|convenience|dynamic|lazy|@\w+)\s+)*func\s+([A-Za-z_][\w]*)"#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:public|private|internal|fileprivate|open|final|indirect|@\w+)\s+)*(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)"#
        )],
        importPatterns: [Rx.compile(#"^(?:@testable\s+)?import\s+([\w.]+)"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|internal|fileprivate|open|static|class|final|override|mutating|required|convenience|@\w+)\s+)*func\s+([A-Za-z_][\w]*)"#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:public|private|internal|fileprivate|open|static|class|final|lazy|weak|unowned|@\w+)\s+)*(?:let|var)\s+([A-Za-z_][\w]*)"#
        ),
        // Swift defaults to internal, which is visible across a whole module —
        // effectively exported for graph purposes.
        exportRule: .all
    )

    static let rust = BraceLanguageSpec(
        languages: ["rust"],
        functionPatterns: [Rx.compile(
            #"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:const\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+([A-Za-z_][\w]*)"#
        )],
        typePatterns: [Rx.compile(
            #"^(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|union)\s+([A-Za-z_][\w]*)"#
        ), Rx.compile(
            #"^impl(?:<[^>]*>)?\s+(?:[\w:<>,\s]+\s+for\s+)?([A-Za-z_][\w]*)"#
        )],
        importPatterns: [
            Rx.compile(#"^(?:pub\s+)?use\s+([\w:{}*,\s]+?)\s*;"#),
            Rx.compile(#"^(?:pub\s+)?mod\s+([A-Za-z_][\w]*)\s*;"#),
        ],
        methodPattern: Rx.compile(
            #"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:const\s+)?(?:unsafe\s+)?fn\s+([A-Za-z_][\w]*)"#
        ),
        propertyPattern: Rx.compile(#"^(?:pub(?:\([^)]*\))?\s+)?([a-z_][\w]*)\s*:"#),
        exportRule: .modifier(["pub"])
    )

    static let php = BraceLanguageSpec(
        languages: ["php"],
        syntax: CommentSyntax(
            lineComment: ["//", "#"],
            blockComment: [(open: "/*", close: "*/")],
            stringDelimiters: ["\"", "'"]
        ),
        functionPatterns: [Rx.compile(
            #"^(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+&?\s*([A-Za-z_][\w]*)\s*\("#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:final|abstract|readonly)\s+)*(?:class|interface|trait|enum)\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [
            Rx.compile(#"^use\s+([\w\\]+)"#),
            Rx.compile(#"^(?:require|include)(?:_once)?\s*\(?\s*['"]([^'"]+)['"]"#),
        ],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+&?\s*([A-Za-z_][\w]*)\s*\("#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:public|private|protected|static|readonly|var)\s+)+\$?([A-Za-z_][\w]*)"#
        ),
        exportRule: .all,
        packagePattern: Rx.compile(#"^namespace\s+([\w\\]+)"#)
    )

    static let dart = BraceLanguageSpec(
        languages: ["dart"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:static|external|abstract|final|const)\s+)*(?:[\w<>,\[\]?]+\s+)?([A-Za-z_][\w]*)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?:async\*?\s*)?\{"#
        )],
        typePatterns: [Rx.compile(
            #"^(?:(?:abstract|final|base|interface|sealed|mixin)\s+)*(?:class|enum|extension|mixin)\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [Rx.compile(#"^(?:import|export|part)\s+['"]([^'"]+)['"]"#)],
        methodPattern: Rx.compile(
            #"^(?:(?:static|external|abstract|final|const|@override)\s+)*(?:[\w<>,\[\]?]+\s+)?([A-Za-z_][\w]*)\s*\("#
        ),
        propertyPattern: Rx.compile(
            #"^(?:(?:static|final|const|late|var)\s+)+(?:[\w<>,\[\]?]+\s+)?([A-Za-z_][\w]*)\s*[=;]"#
        ),
        // Dart's convention is a leading underscore for private.
        exportRule: .all
    )

    static let cFamily = BraceLanguageSpec(
        languages: ["c", "cpp"],
        functionPatterns: [Rx.compile(
            #"^(?:(?:static|inline|extern|const|virtual|explicit|constexpr|friend|_Noreturn)\s+)*[\w:<>,\s*&\[\]]+?[\s*&]([A-Za-z_][\w]*)\s*\([^;]*$"#
        )],
        typePatterns: [Rx.compile(
            #"^(?:typedef\s+)?(?:class|struct|union|enum)(?:\s+class)?\s+([A-Za-z_][\w]*)"#
        )],
        importPatterns: [Rx.compile(##"^#\s*include\s*[<"]([^>"]+)[>"]"##)],
        methodPattern: Rx.compile(
            #"^(?:(?:public|private|protected|static|inline|virtual|explicit|constexpr)\s*:?\s*)*[\w:<>,\s*&\[\]]+?[\s*&]([A-Za-z_][\w]*)\s*\("#
        ),
        propertyPattern: Rx.compile(#"^[\w:<>,\s*&\[\]]+?[\s*&]([A-Za-z_][\w]*)\s*[;=]"#),
        exportRule: .all
    )
}

// MARK: - Concrete extractors

struct JavaExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .java)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct KotlinExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .kotlin)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct ScalaExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .scala)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct CSharpExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .csharp)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct SwiftExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .swift)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct RustExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .rust)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct PHPExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .php)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct DartExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .dart)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}

struct CFamilyExtractor: StructureExtractor {
    private let inner = BraceLanguageExtractor(spec: .cFamily)
    var languages: [String] { inner.languages }
    var syntax: CommentSyntax { inner.syntax }
    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        inner.extract(view, path: path)
    }
}
