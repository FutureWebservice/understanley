import Foundation

/// TypeScript, JavaScript, and the script blocks of Vue and Svelte files.
///
/// Scans top-level declarations only, which matches upstream's tree-sitter
/// extractor (it iterates direct children of the root node and nothing deeper).
/// Interfaces, type aliases and enums are recorded as classes, following
/// upstream's `interface|struct → class` alias.
struct JavaScriptExtractor: StructureExtractor {
    let languages = ["typescript", "javascript", "vue", "svelte"]
    var syntax: CommentSyntax { .jsStyle }

    // MARK: Patterns

    private static let functionDecl = Rx.compile(
        #"^(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#
    )
    /// `const foo = ...` — the right-hand side decides whether it is a function.
    private static let bindingDecl = Rx.compile(
        #"^(?:export\s+)?(?:declare\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]*?)?=\s*(.*)$"#
    )
    private static let classDecl = Rx.compile(
        #"^(?:export\s+)?(?:default\s+)?(?:declare\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)"#
    )
    private static let interfaceDecl = Rx.compile(
        #"^(?:export\s+)?(?:declare\s+)?interface\s+([A-Za-z_$][\w$]*)"#
    )
    private static let typeAliasDecl = Rx.compile(
        #"^(?:export\s+)?(?:declare\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*="#
    )
    private static let enumDecl = Rx.compile(
        #"^(?:export\s+)?(?:declare\s+)?(?:const\s+)?enum\s+([A-Za-z_$][\w$]*)"#
    )

    private static let importFrom = Rx.compile(
        #"^import\s+(?:type\s+)?(.+?)\s+from\s*['"]([^'"]+)['"]"#
    )
    private static let importBare = Rx.compile(#"^import\s*['"]([^'"]+)['"]"#)
    private static let reexportFrom = Rx.compile(
        #"^export\s+(?:type\s+)?(\*(?:\s+as\s+[\w$]+)?|\{[^}]*\})\s*from\s*['"]([^'"]+)['"]"#
    )
    private static let requireCall = Rx.compile(#"require\(\s*['"]([^'"\n]+)['"]\s*\)"#)
    private static let dynamicImport = Rx.compile(#"import\(\s*['"]([^'"\n]+)['"]\s*\)"#)

    private static let exportClause = Rx.compile(#"^export\s+(?:type\s+)?\{([^}]*)\}"#)
    private static let exportDefaultNamed = Rx.compile(
        #"^export\s+default\s+(?:async\s+)?(?:function\s*\*?|class)\s+([A-Za-z_$][\w$]*)"#
    )

    private static let classMethod = Rx.compile(
        #"^(?:(?:public|private|protected|static|readonly|abstract|override|async|get|set|declare)\s+)*\*?\s*(?:#)?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\("#
    )
    private static let classProperty = Rx.compile(
        #"^(?:(?:public|private|protected|static|readonly|abstract|override|declare)\s+)*(?:#)?([A-Za-z_$][\w$]*)\s*[?!]?\s*[:=]"#
    )

    /// Signals that a `const` binding holds a function rather than a value.
    private static let functionRHS = Rx.compile(
        #"^(?:async\s+)?(?:function\b|(?:<[^>]*>\s*)?\([^)]*\)\s*(?::[^=]*)?=>|[A-Za-z_$][\w$]*\s*=>)"#
    )

    // MARK: Extraction

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        var exportedNames = Set<String>()

        // Vue and Svelte put JavaScript inside `<script>` blocks; everything
        // outside is template markup that would otherwise produce nonsense
        // matches. Limiting the scan keeps those files honest.
        let scanRange = Self.scriptRange(in: view, path: path)

        for index in view.topLevelLines where scanRange.contains(index) {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            let isExported = line.hasPrefix("export ")

            // ── Imports and re-exports ──
            //
            // Import statements wrap constantly in real TypeScript:
            //
            //     import type {
            //       Foo,
            //       Bar,
            //     } from "../types.js";
            //
            // Only the first line is at brace depth zero, so the rest is never
            // visited by the top-level scan and the `from "…"` clause is on a
            // line this loop never sees. Rejoining the statement first is what
            // makes import edges exist at all on a typical codebase.
            if line.hasPrefix("import") || line.hasPrefix("export") {
                let statement = Self.joinStatement(view, from: index)

                if let groups = Self.importFrom.firstGroups(in: statement),
                   let clause = groups[group: 1], let source = groups[group: 2] {
                    analysis.imports.append(
                        ImportInfo(source: source,
                                   specifiers: Self.parseImportClause(clause),
                                   lineNumber: index + 1)
                    )
                } else if let groups = Self.importBare.firstGroups(in: statement),
                          let source = groups[group: 1] {
                    analysis.imports.append(
                        ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                    )
                } else if let groups = Self.reexportFrom.firstGroups(in: statement),
                          let clause = groups[group: 1], let source = groups[group: 2] {
                    // A re-export is both an import edge and an export.
                    let names = Self.parseImportClause(clause)
                    analysis.imports.append(
                        ImportInfo(source: source, specifiers: names, lineNumber: index + 1)
                    )
                    for name in names where name != "*" {
                        if exportedNames.insert(name).inserted {
                            analysis.exports.append(
                                ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                            )
                        }
                    }
                    continue
                } else if let groups = Self.exportClause.firstGroups(in: statement),
                          let clause = groups[group: 1] {
                    // A multi-line `export { … }` with no `from`.
                    for name in Self.parseImportClause(clause) where name != "*" {
                        if exportedNames.insert(name).inserted {
                            analysis.exports.append(
                                ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                            )
                        }
                    }
                    continue
                }
            }

            // `require(...)` and `import(...)` can appear anywhere on the line.
            for groups in Self.requireCall.allGroups(in: line) + Self.dynamicImport.allGroups(in: line) {
                if let source = groups[group: 1] {
                    analysis.imports.append(
                        ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                    )
                }
            }

            // ── `export { a, b as c }` ──
            if let groups = Self.exportClause.firstGroups(in: line),
               let clause = groups[group: 1] {
                for name in Self.parseImportClause(clause) where name != "*" {
                    if exportedNames.insert(name).inserted {
                        analysis.exports.append(
                            ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                        )
                    }
                }
                continue
            }

            // ── `export default` ──
            if line.hasPrefix("export default") {
                if let groups = Self.exportDefaultNamed.firstGroups(in: line),
                   let name = groups[group: 1] {
                    // `export default function foo` exports `foo`, not
                    // `default` — the binding has a real name.
                    if exportedNames.insert(name).inserted {
                        analysis.exports.append(
                            ExportInfo(name: name, lineNumber: index + 1, isDefault: true)
                        )
                    }
                } else if exportedNames.insert("default").inserted {
                    analysis.exports.append(
                        ExportInfo(name: "default", lineNumber: index + 1, isDefault: true)
                    )
                }
                // Fall through: `export default class Foo {}` is still a class
                // declaration worth recording.
            }

            // ── Classes, interfaces, enums ──
            if let groups = Self.classDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.blockEnd(from: index)
                let body = (index + 1)..<max(index + 1, end)
                let members = ExtractHelpers.members(
                    in: view, bodyRange: body, headerDepth: 0,
                    methodPattern: Self.classMethod, propertyPattern: Self.classProperty,
                    typeName: name
                )
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: members.methods, properties: members.properties)
                )
                analysis.functions.append(contentsOf: members.functions)
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            if let groups = Self.interfaceDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.blockEnd(from: index)
                let body = (index + 1)..<max(index + 1, end)
                let members = ExtractHelpers.members(
                    in: view, bodyRange: body, headerDepth: 0,
                    methodPattern: Self.classMethod, propertyPattern: Self.classProperty,
                    typeName: name
                )
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: members.methods, properties: members.properties)
                )
                analysis.functions.append(contentsOf: members.functions)
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            if let groups = Self.enumDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.blockEnd(from: index)
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: [], properties: [])
                )
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            if let groups = Self.typeAliasDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                // A type alias occupies one logical statement; use the brace
                // block when it has one, otherwise just its own line.
                let end = line.contains("{") ? view.blockEnd(from: index) : index
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: [], properties: [])
                )
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            // ── Function declarations ──
            if let groups = Self.functionDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.blockEnd(from: index)
                let params = ExtractHelpers.parameters(
                    in: view, startingAt: index,
                    fromOffset: view.text[index].distance(
                        from: view.text[index].startIndex,
                        to: view.text[index].range(of: name)?.lowerBound
                            ?? view.text[index].startIndex
                    )
                )
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: params, returnType: Self.returnType(of: line))
                )
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1,
                                   isDefault: line.contains("export default"))
                    )
                }
                continue
            }

            // ── `const foo = () => {}` and friends ──
            if let groups = Self.bindingDecl.firstGroups(in: line),
               let name = groups[group: 1],
               let rhs = groups[group: 2] {
                let trimmedRHS = rhs.trimmingCharacters(in: .whitespaces)
                let isFunction = Self.functionRHS.matches(trimmedRHS)

                if isFunction {
                    let end = trimmedRHS.hasSuffix("{") || trimmedRHS.contains("{")
                        ? view.blockEnd(from: index)
                        : index
                    let offset = view.text[index].range(of: "=").map {
                        view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                    } ?? 0
                    analysis.functions.append(
                        FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                     params: ExtractHelpers.parameters(
                                         in: view, startingAt: index, fromOffset: offset),
                                     returnType: nil)
                    )
                }
                if isExported, exportedNames.insert(name).inserted {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    // MARK: Helpers

    /// Lines to scan. For `.vue` and `.svelte` this is the `<script>` block;
    /// for everything else it is the whole file.
    private static func scriptRange(in view: SourceView, path: String) -> Range<Int> {
        let ext = PosixPath.fileExtension(path)
        guard ext == ".vue" || ext == ".svelte" else { return 0..<view.count }

        var start: Int?
        var end: Int?
        for (index, line) in view.lines.enumerated() {
            let lower = line.lowercased()
            if start == nil, lower.contains("<script") { start = index + 1 }
            if start != nil, lower.contains("</script") { end = index; break }
        }
        guard let s = start else { return 0..<0 }
        return s..<(end ?? view.count)
    }

    /// Rejoins an import or export statement that wraps across several lines.
    ///
    /// Stops as soon as the joined text forms a complete statement, so a
    /// single-line import costs one regex test and nothing else. The line cap
    /// bounds the work on a file where the statement never completes — a
    /// truncated or malformed source must not send this scanning to EOF.
    static func joinStatement(_ view: SourceView, from index: Int, maxLines: Int = 80) -> String {
        var joined = view.trimmedCode(index)
        var consumed = 0

        while consumed < maxLines {
            if importFrom.matches(joined) || importBare.matches(joined)
                || reexportFrom.matches(joined) || exportClause.matches(joined) {
                return joined
            }
            // A terminated statement with no source clause is complete as it
            // stands — `export default foo;`, for instance.
            if joined.hasSuffix(";") { return joined }
            consumed += 1
            guard index + consumed < view.count else { break }
            let next = view.trimmedCode(index + consumed)
            joined += next.isEmpty ? "" : " " + next
        }
        return joined
    }

    /// Splits an import or export clause into bound names.
    ///
    /// `{ a, b as c }` → `[a, c]`; `* as ns` → `["* as ns"]`;
    /// `Default, { a }` → `[Default, a]`. Aliases resolve to the local name,
    /// because that is the identifier the rest of the file actually uses.
    static func parseImportClause(_ clause: String) -> [String] {
        var names: [String] = []
        var remainder = clause.trimmingCharacters(in: .whitespaces)

        if let open = remainder.firstIndex(of: "{"),
           let close = remainder.lastIndex(of: "}"), open < close {
            let inner = String(remainder[remainder.index(after: open)..<close])
            for part in inner.split(separator: ",") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                guard !piece.isEmpty else { continue }
                let words = piece.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                // `a as b` binds `b`; `type a` binds `a`.
                if words.count >= 3, words[words.count - 2] == "as" {
                    names.append(words[words.count - 1])
                } else if let last = words.last, last != "type" {
                    names.append(last)
                }
            }
            remainder = String(remainder[remainder.startIndex..<open])
        }

        for part in remainder.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if piece.hasPrefix("*") {
                names.append(piece)
            } else if piece != "type" {
                names.append(piece)
            }
        }
        return names
    }

    /// The declared return type, if the signature has one.
    private static func returnType(of line: String) -> String? {
        guard let close = line.lastIndex(of: ")") else { return nil }
        let tail = line[line.index(after: close)...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let type = tail[tail.index(after: colon)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t{;"))
        return type.isEmpty ? nil : type
    }
}
