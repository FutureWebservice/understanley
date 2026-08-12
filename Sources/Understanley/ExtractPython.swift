import Foundation

/// Python. Scope comes from indentation rather than braces, so this extractor
/// uses `SourceView.indent` and `indentBlockEnd` instead of brace matching.
///
/// Python has no export syntax, so — matching upstream — every top-level
/// function and class is recorded as an export. That is what makes `from x
/// import y` resolvable against the defining module later.
struct PythonExtractor: StructureExtractor {
    let languages = ["python"]
    var syntax: CommentSyntax { .python }

    private static let functionDecl = Rx.compile(
        #"^(?:async\s+)?def\s+([A-Za-z_][\w]*)\s*\("#
    )
    private static let classDecl = Rx.compile(#"^class\s+([A-Za-z_][\w]*)"#)
    /// `import a.b`, `import a.b as c`, `import a, b`
    private static let importPlain = Rx.compile(#"^import\s+(.+)$"#)
    /// `from .x.y import a, b` — the module part keeps its leading dots, which
    /// the Python resolver counts to walk up package levels.
    private static let importFrom = Rx.compile(#"^from\s+([.\w]+)\s+import\s+(.+)$"#)
    private static let methodDecl = Rx.compile(#"^(?:async\s+)?def\s+([A-Za-z_][\w]*)\s*\("#)
    private static let annotatedProperty = Rx.compile(#"^([A-Za-z_][\w]*)\s*:\s*[^=]+"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            // Top level means both indent zero and outside any bracket
            // continuation — a `def` inside a multi-line call argument is not a
            // module-level definition.
            guard view.indent[index] == 0, view.depthBefore[index] == 0 else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            // ── from X import a, b ──
            if let groups = Self.importFrom.firstGroups(in: line),
               let module = groups[group: 1],
               let clause = groups[group: 2] {
                analysis.imports.append(
                    ImportInfo(source: module,
                               specifiers: Self.parseImportedNames(clause),
                               lineNumber: index + 1)
                )
                continue
            }

            // ── import a.b, c as d ──
            if line.hasPrefix("import "),
               let groups = Self.importPlain.firstGroups(in: line),
               let clause = groups[group: 1] {
                // Each comma-separated module is its own import edge, matching
                // upstream's one-entry-per-dotted-name behaviour.
                for part in clause.split(separator: ",") {
                    let piece = part.trimmingCharacters(in: .whitespaces)
                    guard !piece.isEmpty else { continue }
                    let words = piece.split(whereSeparator: { $0 == " " }).map(String.init)
                    guard let module = words.first else { continue }
                    let bound = words.count >= 3 && words[1] == "as" ? words[2] : module
                    analysis.imports.append(
                        ImportInfo(source: module, specifiers: [bound], lineNumber: index + 1)
                    )
                }
                continue
            }

            // ── class ──
            if let groups = Self.classDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.indentBlockEnd(from: index)
                let members = Self.classMembers(in: view, header: index, end: end, typeName: name)
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: members.methods, properties: members.properties)
                )
                analysis.functions.append(contentsOf: members.functions)
                analysis.exports.append(
                    ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                )
                continue
            }

            // ── def ──
            if let groups = Self.functionDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.indentBlockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                analysis.functions.append(
                    FunctionInfo(
                        name: name,
                        lineRange: LineRange(index + 1, end + 1),
                        params: ExtractHelpers.parameters(
                            in: view, startingAt: index, fromOffset: offset, dropSelf: true),
                        returnType: Self.returnType(of: line)
                    )
                )
                analysis.exports.append(
                    ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                )
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    /// Methods and annotated attributes declared directly in a class body.
    ///
    /// Methods are returned as full `FunctionInfo` values so they become nodes
    /// in their own right — see `ExtractHelpers.members` for why that matters.
    private static func classMembers(
        in view: SourceView, header: Int, end: Int, typeName: String
    ) -> ExtractHelpers.Members {
        var out = ExtractHelpers.Members()
        var bodyIndent: Int?

        var index = header + 1
        while index <= end, index < view.count {
            defer { index += 1 }
            let raw = view.lines[index]
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // The first non-blank line establishes the body's indent; anything
            // deeper is inside a method, not a member of the class.
            if bodyIndent == nil { bodyIndent = view.indent[index] }
            guard view.indent[index] == bodyIndent else { continue }

            let line = view.trimmedCode(index)
            if let name = methodDecl.group(1, in: line) {
                out.methods.append(name)
                let methodEnd = view.indentBlockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                out.functions.append(
                    FunctionInfo(
                        name: "\(typeName).\(name)",
                        lineRange: LineRange(index + 1, methodEnd + 1),
                        params: ExtractHelpers.parameters(
                            in: view, startingAt: index, fromOffset: offset, dropSelf: true),
                        returnType: returnType(of: line)
                    )
                )
            } else if let name = annotatedProperty.group(1, in: line) {
                out.properties.append(name)
            }
        }
        return out
    }

    /// Names bound by a `from … import …` clause. `*` is preserved because the
    /// resolver treats a wildcard import differently from a named one.
    private static func parseImportedNames(_ clause: String) -> [String] {
        var text = clause.trimmingCharacters(in: .whitespaces)
        // Parenthesised multi-line import lists.
        if text.hasPrefix("(") { text = String(text.dropFirst()) }
        if text.hasSuffix(")") { text = String(text.dropLast()) }

        var names: [String] = []
        for part in text.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let words = piece.split(whereSeparator: { $0 == " " }).map(String.init)
            if words.count >= 3, words[1] == "as" {
                names.append(words[2])
            } else if let first = words.first {
                names.append(first)
            }
        }
        return names
    }

    private static func returnType(of line: String) -> String? {
        guard let arrow = line.range(of: "->") else { return nil }
        let type = line[arrow.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
        return type.isEmpty ? nil : type
    }
}
