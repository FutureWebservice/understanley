import Foundation

// MARK: - Go

/// Go. Handled separately from the generic brace driver because of two
/// language-specific shapes: methods carry a receiver that binds them to a
/// type declared elsewhere in the file, and imports usually arrive as a
/// parenthesised block rather than one statement per line.
struct GoExtractor: StructureExtractor {
    let languages = ["go"]

    private static let funcDecl = Rx.compile(#"^func\s+([A-Za-z_][\w]*)\s*(?:\[[^\]]*\])?\s*\("#)
    /// `func (r *Repo) Save(...)` — group 1 is the receiver type, group 2 the
    /// method name.
    private static let methodDecl = Rx.compile(
        #"^func\s*\(\s*\w+\s+\*?([A-Za-z_][\w]*)\s*\)\s*([A-Za-z_][\w]*)\s*\("#
    )
    private static let typeDecl = Rx.compile(
        #"^type\s+([A-Za-z_][\w]*)(?:\[[^\]]*\])?\s+(struct|interface|=|[\w\[\]*.]+)"#
    )
    private static let importSingle = Rx.compile(#"^import\s+(?:(\w+|\.|_)\s+)?"([^"]+)""#)
    private static let importInBlock = Rx.compile(#"^(?:(\w+|\.|_)\s+)?"([^"]+)"$"#)
    private static let packageDecl = Rx.compile(#"^package\s+([A-Za-z_][\w]*)"#)
    private static let structField = Rx.compile(#"^([A-Za-z_][\w]*)\s+[\w\[\]*.<>{}\s]+"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        // Receiver type → method names, attached after all types are known.
        var methodsByReceiver: [String: [String]] = [:]
        var inImportBlock = false

        // Every line is visited, not just the top-level ones. Go's grouped
        // import form
        //
        //     import (
        //         "fmt"
        //     )
        //
        // puts its entries at paren depth 1, so a top-level-only scan never
        // sees them *or* the closing paren — leaving the block flag stuck on
        // and silently discarding the whole rest of the file. Declarations
        // still require depth zero; only the import block reads deeper.
        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            // ── import ( … ) ──
            if inImportBlock {
                if line.hasPrefix(")") { inImportBlock = false; continue }
                if let groups = Self.importInBlock.firstGroups(in: line),
                   let source = groups[group: 2] {
                    let alias = groups[group: 1]
                    analysis.imports.append(
                        ImportInfo(source: source,
                                   specifiers: [alias ?? Self.packageName(of: source)],
                                   lineNumber: index + 1)
                    )
                }
                continue
            }
            if line.hasPrefix("import (") { inImportBlock = true; continue }

            // Past the import block, only top-level lines declare anything.
            guard view.depthBefore[index] == 0 else { continue }

            if let groups = Self.importSingle.firstGroups(in: line),
               let source = groups[group: 2] {
                let alias = groups[group: 1]
                analysis.imports.append(
                    ImportInfo(source: source,
                               specifiers: [alias ?? Self.packageName(of: source)],
                               lineNumber: index + 1)
                )
                continue
            }

            if let groups = Self.packageDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                analysis.imports.append(
                    ImportInfo(source: "package:" + name, specifiers: [], lineNumber: index + 1)
                )
                continue
            }

            // ── Methods (checked before plain funcs — both start with `func`) ──
            if let groups = Self.methodDecl.firstGroups(in: line),
               let receiver = groups[group: 1],
               let name = groups[group: 2] {
                let end = view.blockEnd(from: index)
                methodsByReceiver[receiver, default: []].append(name)
                let offset = view.text[index].range(of: ")").map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: ExtractHelpers.parameters(
                                     in: view, startingAt: index, fromOffset: offset),
                                 returnType: nil)
                )
                if ExtractHelpers.isCapitalised(name) {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            if let groups = Self.funcDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.blockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: ExtractHelpers.parameters(
                                     in: view, startingAt: index, fromOffset: offset),
                                 returnType: nil)
                )
                if ExtractHelpers.isCapitalised(name) {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            // ── Types. Structs and interfaces both become class nodes. ──
            if let groups = Self.typeDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let hasBody = line.contains("{")
                let end = hasBody ? view.blockEnd(from: index) : index
                var properties: [String] = []
                if hasBody {
                    for bodyIndex in (index + 1)..<max(index + 1, end)
                    where bodyIndex < view.count && view.depthBefore[bodyIndex] == 1 {
                        let field = view.trimmedCode(bodyIndex)
                        if let fieldName = Self.structField.group(1, in: field) {
                            properties.append(fieldName)
                        }
                    }
                }
                analysis.classes.append(
                    ClassInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                              methods: [], properties: properties)
                )
                if ExtractHelpers.isCapitalised(name) {
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
            }
        }

        // Attach methods to their receivers now that every type is known.
        for i in analysis.classes.indices {
            if let methods = methodsByReceiver[analysis.classes[i].name] {
                analysis.classes[i].methods = methods
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    /// Last component of an import path, which is the package's bound name.
    private static func packageName(of importPath: String) -> String {
        importPath.split(separator: "/").last.map(String.init) ?? importPath
    }
}

// MARK: - Ruby

/// Ruby. Blocks end with `end` rather than a brace, so spans come from
/// indentation.
struct RubyExtractor: StructureExtractor {
    let languages = ["ruby"]
    var syntax: CommentSyntax { .ruby }

    private static let defDecl = Rx.compile(#"^def\s+(?:self\.)?([A-Za-z_][\w]*[?!=]?)"#)
    private static let classDecl = Rx.compile(#"^(?:class|module)\s+([A-Za-z_][\w:]*)"#)
    private static let requireDecl = Rx.compile(
        #"^require(?:_relative)?\s*\(?\s*['"]([^'"]+)['"]"#
    )
    private static let attrDecl = Rx.compile(#"^attr_(?:accessor|reader|writer)\s+(.+)$"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            guard view.indent[index] == 0, view.depthBefore[index] == 0 else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if let groups = Self.requireDecl.firstGroups(in: line),
               let source = groups[group: 1] {
                analysis.imports.append(
                    ImportInfo(source: source,
                               specifiers: [PosixPath.basename(source)],
                               lineNumber: index + 1)
                )
                continue
            }

            if let groups = Self.classDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.indentBlockEnd(from: index)
                let members = Self.members(in: view, header: index, end: end, typeName: name)
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

            if let groups = Self.defDecl.firstGroups(in: line),
               let name = groups[group: 1] {
                let end = view.indentBlockEnd(from: index)
                let offset = view.text[index].range(of: name).map {
                    view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
                } ?? 0
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: ExtractHelpers.parameters(
                                     in: view, startingAt: index, fromOffset: offset),
                                 returnType: nil)
                )
                analysis.exports.append(
                    ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                )
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    private static func members(
        in view: SourceView, header: Int, end: Int, typeName: String
    ) -> ExtractHelpers.Members {
        var out = ExtractHelpers.Members()
        var bodyIndent: Int?

        var index = header + 1
        while index <= end, index < view.count {
            defer { index += 1 }
            guard !view.lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if bodyIndent == nil { bodyIndent = view.indent[index] }
            guard view.indent[index] == bodyIndent else { continue }

            let line = view.trimmedCode(index)
            if let name = defDecl.group(1, in: line) {
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
                            in: view, startingAt: index, fromOffset: offset),
                        returnType: nil
                    )
                )
            } else if let clause = attrDecl.group(1, in: line) {
                // `attr_accessor :name, :size` declares properties.
                for part in clause.split(separator: ",") {
                    let symbol = part.trimmingCharacters(in: CharacterSet(charactersIn: " :\"'"))
                    if !symbol.isEmpty { out.properties.append(symbol) }
                }
            }
        }
        return out
    }
}

// MARK: - Lua

struct LuaExtractor: StructureExtractor {
    let languages = ["lua"]
    var syntax: CommentSyntax {
        CommentSyntax(lineComment: ["--"], blockComment: [(open: "--[[", close: "]]")],
                      stringDelimiters: ["\"", "'"])
    }

    private static let funcDecl = Rx.compile(
        #"^(?:local\s+)?function\s+(?:[\w.]+[.:])?([A-Za-z_][\w]*)\s*\("#
    )
    private static let assignedFunc = Rx.compile(
        #"^(?:local\s+)?([A-Za-z_][\w]*)\s*=\s*function\s*\("#
    )
    private static let requireDecl = Rx.compile(#"require\s*\(?\s*['"]([^'"]+)['"]"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            guard view.indent[index] == 0 else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            for groups in Self.requireDecl.allGroups(in: line) {
                if let source = groups[group: 1] {
                    analysis.imports.append(
                        ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                    )
                }
            }

            let name = Self.funcDecl.group(1, in: line)
                ?? Self.assignedFunc.group(1, in: line)
            guard let name else { continue }

            let end = view.indentBlockEnd(from: index)
            let offset = view.text[index].range(of: name).map {
                view.text[index].distance(from: view.text[index].startIndex, to: $0.upperBound)
            } ?? 0
            analysis.functions.append(
                FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                             params: ExtractHelpers.parameters(
                                 in: view, startingAt: index, fromOffset: offset),
                             returnType: nil)
            )
            if !line.hasPrefix("local") {
                analysis.exports.append(
                    ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                )
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }
}

// MARK: - Shell

/// POSIX shell and Bash. Upstream's tree-sitter set has no shell grammar, so
/// its file-analyzer prompt asks the model to recover shell functions by hand;
/// doing it deterministically here means shell scripts get real function nodes
/// with no LLM involved.
struct ShellExtractor: StructureExtractor {
    let languages = ["shell", "jenkinsfile"]
    var syntax: CommentSyntax { .shell }

    private static let funcParen = Rx.compile(#"^([A-Za-z_][\w-]*)\s*\(\s*\)"#)
    private static let funcKeyword = Rx.compile(#"^function\s+([A-Za-z_][\w-]*)\s*(?:\(\s*\))?"#)
    private static let sourceDecl = Rx.compile(#"^(?:source|\.)\s+["']?([^"'\s;]+)"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if let groups = Self.sourceDecl.firstGroups(in: line),
               let source = groups[group: 1] {
                analysis.imports.append(
                    ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                )
                continue
            }

            guard view.indent[index] == 0 else { continue }
            let name = Self.funcParen.group(1, in: line)
                ?? Self.funcKeyword.group(1, in: line)
            guard let name else { continue }

            // A function header must be followed by an opening brace, on this
            // line or the next non-blank one. Without that check, a bare call
            // like `cleanup()` reads as a declaration.
            var end = index
            if line.contains("{") {
                end = view.blockEnd(from: index)
            } else if index + 1 < view.count, view.trimmedCode(index + 1).hasPrefix("{") {
                end = view.blockEnd(from: index + 1)
            } else {
                continue
            }

            analysis.functions.append(
                FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                             params: [], returnType: nil)
            )
            analysis.exports.append(
                ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
            )
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }
}

// MARK: - PowerShell

struct PowerShellExtractor: StructureExtractor {
    let languages = ["powershell", "batch"]
    var syntax: CommentSyntax {
        CommentSyntax(lineComment: ["#"], blockComment: [(open: "<#", close: "#>")],
                      stringDelimiters: ["\"", "'"], escape: "`", hashIsComment: true)
    }

    private static let funcDecl = Rx.compile(
        #"^function\s+([A-Za-z_][\w-]*)"#, options: [.caseInsensitive]
    )
    private static let importDecl = Rx.compile(
        #"^(?:Import-Module|\.)\s+["']?([^"'\s;]+)"#, options: [.caseInsensitive]
    )
    /// Batch labels double as call targets, which is the closest thing the
    /// language has to a function.
    private static let batchLabel = Rx.compile(#"^:([A-Za-z_][\w]*)\s*$"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        let isBatch = PosixPath.fileExtension(path) == ".bat"
            || PosixPath.fileExtension(path) == ".cmd"

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if isBatch {
                if let name = Self.batchLabel.group(1, in: line) {
                    analysis.functions.append(
                        FunctionInfo(name: name, lineRange: LineRange(index + 1, index + 1),
                                     params: [], returnType: nil)
                    )
                    analysis.exports.append(
                        ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                    )
                }
                continue
            }

            if let groups = Self.importDecl.firstGroups(in: line),
               let source = groups[group: 1] {
                analysis.imports.append(
                    ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                )
                continue
            }

            if let name = Self.funcDecl.group(1, in: line) {
                let end = view.blockEnd(from: index)
                analysis.functions.append(
                    FunctionInfo(name: name, lineRange: LineRange(index + 1, end + 1),
                                 params: Self.paramBlock(in: view, from: index, to: end),
                                 returnType: nil)
                )
                analysis.exports.append(
                    ExportInfo(name: name, lineNumber: index + 1, isDefault: false)
                )
            }
        }

        analysis.callGraph = CallGraph.extract(from: view, functions: analysis.functions)
        return analysis
    }

    /// PowerShell declares parameters in a `param(...)` block inside the
    /// function body rather than in its signature.
    private static func paramBlock(in view: SourceView, from start: Int, to end: Int) -> [String] {
        for index in start...min(end, view.count - 1) {
            let line = view.trimmedCode(index)
            guard line.lowercased().hasPrefix("param") else { continue }
            var text = view.text[index]
            var consumed = 0
            while ParamParser.balanced(text, from: text.startIndex) == nil,
                  consumed < 20, index + consumed + 1 < view.count {
                consumed += 1
                text += " " + view.text[index + consumed]
            }
            guard let group = ParamParser.balanced(text, from: text.startIndex) else { return [] }
            return ParamParser.names(from: group.inner)
                .map { $0.hasPrefix("$") ? String($0.dropFirst()) : $0 }
        }
        return []
    }
}
