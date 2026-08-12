import Foundation

// Parsers for the file types that are not source code but carry just as much
// architectural meaning: what gets deployed, what the schema is, what the CI
// does, what the docs point at. Upstream registers twelve of these and they are
// the reason a knowledge graph shows infrastructure and data alongside code
// rather than only the `.ts` files.
//
// Each populates the parts of `StructuralAnalysis` that fit its format:
// `sections` for headings and top-level keys, `definitions` for schema objects,
// `services`/`endpoints`/`steps`/`resources` for the sub-file nodes the graph
// builder turns into their own node types.

// MARK: - Markdown

struct MarkdownParser: StructureExtractor {
    let languages = ["markdown", "restructuredtext", "plaintext"]
    var syntax: CommentSyntax { .none }

    private static let heading = Rx.compile(#"^(#{1,6})\s+(.+)$"#)
    /// Inline links and images. A leading `!` marks an image.
    private static let link = Rx.compile(#"(!?)\[([^\]]*)\]\(([^)\s]+)"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        var open: [(name: String, level: Int, start: Int)] = []
        var inFence = false
        var fenceMarker: Character = "`"

        for index in 0..<view.count {
            let raw = view.lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Track fenced code blocks so a `# comment` inside a shell snippet
            // is not mistaken for a heading.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first ?? "`"
                if !inFence {
                    inFence = true
                    fenceMarker = marker
                } else if marker == fenceMarker {
                    inFence = false
                }
                continue
            }
            if inFence { continue }

            if let groups = Self.heading.firstGroups(in: trimmed),
               let hashes = groups[group: 1],
               let title = groups[group: 2] {
                let level = hashes.count
                // A heading closes every open section at its level or deeper.
                while let last = open.last, last.level >= level {
                    analysis.sections.append(
                        SectionInfo(name: last.name, level: last.level,
                                    lineRange: LineRange(last.start + 1, index))
                    )
                    open.removeLast()
                }
                open.append((title.trimmingCharacters(in: .whitespaces), level, index))
                continue
            }

            // Links to project files become `documents` edges later. External
            // URLs and anchors are not part of the graph.
            for groups in Self.link.allGroups(in: raw) {
                guard let target = groups[group: 3] else { continue }
                if target.hasPrefix("http") || target.hasPrefix("#") || target.hasPrefix("mailto:") {
                    continue
                }
                analysis.imports.append(
                    ImportInfo(source: target, specifiers: [], lineNumber: index + 1)
                )
            }
        }

        for last in open.reversed() {
            analysis.sections.append(
                SectionInfo(name: last.name, level: last.level,
                            lineRange: LineRange(last.start + 1, view.count))
            )
        }
        analysis.sections.sort { $0.lineRange.start < $1.lineRange.start }
        return analysis
    }
}

// MARK: - YAML

struct YAMLParser: StructureExtractor {
    let languages = ["yaml", "kubernetes", "github-actions", "openapi", "docker-compose"]
    var syntax: CommentSyntax { .hashOnly }

    /// A top-level mapping key, optionally quoted — GitHub Actions writes
    /// `"on":` because bare `on` is a YAML boolean.
    private static let topKey = Rx.compile(#"^["']?([\w.-]+)["']?\s*:"#)
    private static let listItemName = Rx.compile(#"^\s*-\s+(?:name|id|kind)\s*:\s*["']?([^"'\n]+)"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        let posix = PosixPath.normalize(path)
        let isWorkflow = posix.hasPrefix(".github/workflows/")
            || posix.hasPrefix(".circleci/")
            || PosixPath.basename(posix) == ".gitlab-ci.yml"
        let isCompose = PosixPath.basename(posix).hasPrefix("docker-compose")
            || PosixPath.basename(posix).hasPrefix("compose.")

        var openKey: (name: String, start: Int)?

        for index in 0..<view.count {
            guard view.indent[index] == 0 else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty, !line.hasPrefix("-"), !line.hasPrefix("#") else { continue }

            guard let key = Self.topKey.group(1, in: line) else { continue }
            if let previous = openKey {
                analysis.sections.append(
                    SectionInfo(name: previous.name, level: 1,
                                lineRange: LineRange(previous.start + 1, index))
                )
            }
            openKey = (key, index)
        }
        if let previous = openKey {
            analysis.sections.append(
                SectionInfo(name: previous.name, level: 1,
                            lineRange: LineRange(previous.start + 1, view.count))
            )
        }

        if isWorkflow {
            analysis.steps = Self.workflowSteps(in: view)
        }
        if isCompose {
            analysis.services = Self.composeServices(in: view, sections: analysis.sections)
        }
        return analysis
    }

    /// Jobs and named steps in a CI workflow. Both become `step` nodes so a
    /// pipeline shows its stages rather than being one opaque file.
    private static func workflowSteps(in view: SourceView) -> [StepInfo] {
        var steps: [StepInfo] = []
        var inJobs = false
        var jobIndent = 0

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if view.indent[index] == 0 {
                inJobs = line.hasPrefix("jobs:")
                continue
            }
            if inJobs {
                // The first nested level under `jobs:` is a job name.
                if jobIndent == 0 { jobIndent = view.indent[index] }
                if view.indent[index] == jobIndent, let key = topKey.group(1, in: line) {
                    steps.append(
                        StepInfo(name: key, lineRange: LineRange(index + 1,
                                                                 view.indentBlockEnd(from: index) + 1))
                    )
                    continue
                }
            }
            if let name = listItemName.group(1, in: view.lines[index]) {
                let trimmedName = name.trimmingCharacters(in: .whitespaces)
                if !trimmedName.isEmpty {
                    steps.append(StepInfo(name: trimmedName, lineRange: LineRange(index + 1, index + 1)))
                }
            }
        }
        return steps
    }

    /// Services declared in a compose file, with any published ports.
    private static func composeServices(in view: SourceView, sections: [SectionInfo]) -> [ServiceInfo] {
        guard let servicesSection = sections.first(where: { $0.name == "services" }) else { return [] }
        var services: [ServiceInfo] = []
        var serviceIndent: Int?

        let start = servicesSection.lineRange.start // 1-based header line
        let end = min(servicesSection.lineRange.end, view.count)
        guard start < end else { return [] }

        for index in start..<end {
            let line = view.trimmedCode(index)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if serviceIndent == nil, view.indent[index] > 0 { serviceIndent = view.indent[index] }
            guard view.indent[index] == serviceIndent, let name = topKey.group(1, in: line) else {
                continue
            }
            let blockEnd = view.indentBlockEnd(from: index)
            services.append(
                ServiceInfo(name: name,
                            image: Self.value(of: "image", in: view, from: index, to: blockEnd),
                            ports: Self.ports(in: view, from: index, to: blockEnd),
                            lineRange: LineRange(index + 1, blockEnd + 1))
            )
        }
        return services
    }

    private static func value(of key: String, in view: SourceView, from: Int, to: Int) -> String? {
        for index in from...min(to, view.count - 1) {
            let line = view.trimmedCode(index)
            guard line.hasPrefix(key + ":") else { continue }
            let value = line.dropFirst(key.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static let portNumber = Rx.compile(#"(\d{2,5})"#)

    private static func ports(in view: SourceView, from: Int, to: Int) -> [Int] {
        var found: [Int] = []
        var inPorts = false
        for index in from...min(to, view.count - 1) {
            let line = view.trimmedCode(index)
            if line.hasPrefix("ports:") { inPorts = true; continue }
            if inPorts {
                guard line.hasPrefix("-") else { if !line.isEmpty { inPorts = false }; continue }
                for groups in portNumber.allGroups(in: line) {
                    if let text = groups[group: 1], let port = Int(text) {
                        found.append(port)
                    }
                }
            }
        }
        return Array(Set(found)).sorted()
    }
}

// MARK: - JSON

struct JSONParser: StructureExtractor {
    let languages = ["json", "jsonc", "json-schema"]
    var syntax: CommentSyntax { .none }

    private static let topKey = Rx.compile(#"^"([^"]+)"\s*:"#)
    private static let refValue = Rx.compile(#""\$ref"\s*:\s*"([^"]+)""#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            // Top-level keys sit exactly one brace deep.
            guard view.depthBefore[index] == 1 else {
                // `$ref` pointers can appear at any depth and are real
                // dependencies between schema files.
                if let ref = Self.refValue.group(1, in: view.lines[index]), !ref.hasPrefix("#") {
                    analysis.imports.append(
                        ImportInfo(source: ref, specifiers: [], lineNumber: index + 1)
                    )
                }
                continue
            }
            let line = view.trimmedCode(index)
            guard let key = Self.topKey.group(1, in: line) else { continue }
            analysis.sections.append(
                SectionInfo(name: key, level: 1,
                            lineRange: LineRange(index + 1, view.blockEnd(from: index) + 1))
            )
        }
        return analysis
    }
}

// MARK: - TOML

struct TOMLParser: StructureExtractor {
    let languages = ["toml"]
    var syntax: CommentSyntax { .hashOnly }

    private static let table = Rx.compile(#"^\s*\[(\[?)([^\]]+)\]?\]"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        var open: (name: String, start: Int)?

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard let groups = Self.table.firstGroups(in: line),
                  let name = groups[group: 2] else { continue }
            let isArray = (groups[group: 1]) == "["
            let display = isArray ? "[[\(name)]]" : name

            if let previous = open {
                analysis.sections.append(
                    SectionInfo(name: previous.name,
                                level: previous.name.split(separator: ".").count,
                                lineRange: LineRange(previous.start + 1, index))
                )
            }
            open = (display, index)
        }
        if let previous = open {
            analysis.sections.append(
                SectionInfo(name: previous.name,
                            level: previous.name.split(separator: ".").count,
                            lineRange: LineRange(previous.start + 1, view.count))
            )
        }
        return analysis
    }
}

// MARK: - .env

struct EnvParser: StructureExtractor {
    let languages = ["env", "config", "properties"]
    var syntax: CommentSyntax { .hashOnly }

    private static let assignment = Rx.compile(#"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*="#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        for index in 0..<view.count {
            let line = view.lines[index].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let name = Self.assignment.group(1, in: line) else { continue }
            analysis.definitions.append(
                DefinitionInfo(name: name, kind: "variable",
                               lineRange: LineRange(index + 1, index + 1), fields: [])
            )
        }
        return analysis
    }
}

// MARK: - Dockerfile

struct DockerfileParser: StructureExtractor {
    let languages = ["dockerfile"]
    var syntax: CommentSyntax { .hashOnly }

    private static let fromDirective = Rx.compile(
        #"^FROM\s+(\S+)(?:\s+AS\s+(\S+))?"#, options: [.caseInsensitive]
    )
    private static let directive = Rx.compile(
        #"^(FROM|RUN|COPY|ADD|WORKDIR|CMD|ENTRYPOINT|ENV|ARG|EXPOSE|VOLUME|USER|HEALTHCHECK)\s+(.*)$"#,
        options: [.caseInsensitive]
    )
    private static let exposeDirective = Rx.compile(#"^EXPOSE\s+(.*)$"#, options: [.caseInsensitive])

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        // Every FROM opens a build stage; a multi-stage Dockerfile is several
        // services in one file, and each deserves its own node.
        var stageStarts: [(name: String, image: String, line: Int)] = []
        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard let groups = Self.fromDirective.firstGroups(in: line),
                  let image = groups[group: 1] else { continue }
            let alias = groups[group: 2]
            let name = alias ?? Self.defaultStageName(for: image)
            stageStarts.append((name, image, index))
        }

        for (offset, stage) in stageStarts.enumerated() {
            let end = offset + 1 < stageStarts.count ? stageStarts[offset + 1].line - 1 : view.count - 1
            analysis.services.append(
                ServiceInfo(name: stage.name, image: stage.image,
                            ports: Self.ports(in: view, from: stage.line, to: end),
                            lineRange: LineRange(stage.line + 1, end + 1))
            )
        }

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard let groups = Self.directive.firstGroups(in: line),
                  let verb = groups[group: 1],
                  let rest = groups[group: 2] else { continue }
            let summary = rest.trimmingCharacters(in: .whitespaces)
            analysis.steps.append(
                StepInfo(name: "\(verb.uppercased()) \(String(summary.prefix(60)))",
                         lineRange: LineRange(index + 1, index + 1))
            )
        }
        return analysis
    }

    private static func defaultStageName(for image: String) -> String {
        let withoutTag = image.split(separator: ":").first.map(String.init) ?? image
        return withoutTag.split(separator: "/").last.map(String.init) ?? withoutTag
    }

    private static func ports(in view: SourceView, from: Int, to: Int) -> [Int] {
        var found: [Int] = []
        for index in from...min(to, view.count - 1) {
            guard let rest = exposeDirective.group(1, in: view.trimmedCode(index)) else { continue }
            for token in rest.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let number = token.split(separator: "/").first.map(String.init) ?? String(token)
                if let port = Int(number) { found.append(port) }
            }
        }
        return Array(Set(found)).sorted()
    }
}

// MARK: - SQL

struct SQLParser: StructureExtractor {
    let languages = ["sql"]
    var syntax: CommentSyntax { .sqlStyle }

    private static let createTable = Rx.compile(
        #"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TEMP(?:ORARY)?\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`"\[]?([\w.]+)[`"\]]?"#,
        options: [.caseInsensitive]
    )
    private static let createView = Rx.compile(
        #"CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?[`"\[]?([\w.]+)[`"\]]?"#,
        options: [.caseInsensitive]
    )
    private static let createIndex = Rx.compile(
        #"CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?[`"\[]?([\w.]+)[`"\]]?"#,
        options: [.caseInsensitive]
    )
    private static let alterTable = Rx.compile(
        #"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?[`"\[]?([\w.]+)[`"\]]?"#, options: [.caseInsensitive]
    )
    /// Constraint keywords that open a table-level clause rather than a column.
    private static let constraintKeywords = ["primary", "foreign", "unique", "check", "constraint", "index", "key"]

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        var seen = Set<String>()

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if let name = Self.createTable.group(1, in: line) {
                let end = Self.statementEnd(in: view, from: index)
                if seen.insert("table:" + name).inserted {
                    analysis.definitions.append(
                        DefinitionInfo(name: name, kind: "table",
                                       lineRange: LineRange(index + 1, end + 1),
                                       fields: Self.columns(in: view, from: index, to: end))
                    )
                }
                continue
            }
            if let name = Self.createView.group(1, in: line) {
                let end = Self.statementEnd(in: view, from: index)
                if seen.insert("view:" + name).inserted {
                    analysis.definitions.append(
                        DefinitionInfo(name: name, kind: "view",
                                       lineRange: LineRange(index + 1, end + 1), fields: [])
                    )
                }
                continue
            }
            if let name = Self.createIndex.group(1, in: line) {
                if seen.insert("index:" + name).inserted {
                    analysis.definitions.append(
                        DefinitionInfo(name: name, kind: "index",
                                       lineRange: LineRange(index + 1, index + 1), fields: [])
                    )
                }
                continue
            }
            // A migration that alters a table is a relationship to that table,
            // even though it does not define it.
            if let name = Self.alterTable.group(1, in: line) {
                if seen.insert("alter:" + name).inserted {
                    analysis.imports.append(
                        ImportInfo(source: "table:" + name, specifiers: [], lineNumber: index + 1)
                    )
                }
            }
        }
        return analysis
    }

    /// End of the statement: the line carrying its terminating semicolon.
    private static func statementEnd(in view: SourceView, from start: Int) -> Int {
        for index in start..<view.count where view.text[index].contains(";") {
            return index
        }
        return min(start + 40, view.count - 1)
    }

    private static func columns(in view: SourceView, from start: Int, to end: Int) -> [String] {
        var fields: [String] = []
        guard start < end else { return [] }
        for index in (start + 1)...end {
            guard index < view.count else { break }
            let line = view.trimmedCode(index)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t,()"))
            guard !line.isEmpty else { continue }
            let firstWord = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" })
                .first.map(String.init) ?? ""
            guard !firstWord.isEmpty else { continue }
            if constraintKeywords.contains(firstWord.lowercased()) { continue }
            let name = firstWord.trimmingCharacters(in: CharacterSet(charactersIn: "`\"[];,()"))
            // The statement's closing `);` line trims to nothing — a column
            // name has to actually look like an identifier.
            guard let first = name.first, first.isLetter || first == "_" else { continue }
            fields.append(name)
        }
        return fields
    }
}

// MARK: - GraphQL

struct GraphQLParser: StructureExtractor {
    let languages = ["graphql"]
    var syntax: CommentSyntax { .hashOnly }

    private static let typeDecl = Rx.compile(
        #"^(type|input|enum|interface|union|scalar)\s+([A-Za-z_][\w]*)"#
    )
    private static let fieldDecl = Rx.compile(#"^([A-Za-z_][\w]*)\s*(?:\([^)]*\))?\s*:"#)
    /// Root operation types, whose fields are the API surface.
    private static let rootTypes: Set<String> = ["Query", "Mutation", "Subscription"]

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in view.topLevelLines {
            let line = view.trimmedCode(index)
            guard let groups = Self.typeDecl.firstGroups(in: line),
                  let kind = groups[group: 1],
                  let name = groups[group: 2] else { continue }

            let hasBody = line.contains("{")
            let end = hasBody ? view.blockEnd(from: index) : index
            let fields = hasBody ? Self.fields(in: view, from: index, to: end) : []

            if Self.rootTypes.contains(name) {
                // Query/Mutation fields are endpoints, not a data type.
                for (field, line) in fields {
                    analysis.endpoints.append(
                        EndpointInfo(method: name, path: field, lineRange: LineRange(line, line))
                    )
                }
                continue
            }

            analysis.definitions.append(
                DefinitionInfo(name: name, kind: kind,
                               lineRange: LineRange(index + 1, end + 1),
                               fields: fields.map(\.0))
            )
        }
        return analysis
    }

    private static func fields(in view: SourceView, from start: Int, to end: Int) -> [(String, Int)] {
        var out: [(String, Int)] = []
        guard start + 1 <= end else { return [] }
        for index in (start + 1)..<min(end, view.count) {
            guard view.depthBefore[index] == 1 else { continue }
            let line = view.trimmedCode(index)
            guard let name = fieldDecl.group(1, in: line) else { continue }
            out.append((name, index + 1))
        }
        return out
    }
}

// MARK: - Protobuf

struct ProtobufParser: StructureExtractor {
    let languages = ["protobuf"]

    private static let messageDecl = Rx.compile(#"^message\s+([A-Za-z_][\w]*)"#)
    private static let enumDecl = Rx.compile(#"^enum\s+([A-Za-z_][\w]*)"#)
    private static let serviceDecl = Rx.compile(#"^service\s+([A-Za-z_][\w]*)"#)
    private static let rpcDecl = Rx.compile(#"rpc\s+([A-Za-z_][\w]*)\s*\("#)
    private static let fieldDecl = Rx.compile(
        #"^(?:repeated\s+|optional\s+|required\s+|map<[^>]+>\s+)?[\w.]+\s+([A-Za-z_][\w]*)\s*="#
    )
    private static let enumValue = Rx.compile(#"^([A-Za-z_][\w]*)\s*="#)
    private static let importDecl = Rx.compile(#"^import\s+(?:public\s+)?"([^"]+)""#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in view.topLevelLines {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if let source = Self.importDecl.group(1, in: line) {
                analysis.imports.append(
                    ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                )
                continue
            }

            if let name = Self.messageDecl.group(1, in: line) {
                let end = view.blockEnd(from: index)
                analysis.definitions.append(
                    DefinitionInfo(name: name, kind: "message",
                                   lineRange: LineRange(index + 1, end + 1),
                                   fields: Self.members(in: view, from: index, to: end,
                                                        pattern: Self.fieldDecl))
                )
                continue
            }

            if let name = Self.enumDecl.group(1, in: line) {
                let end = view.blockEnd(from: index)
                analysis.definitions.append(
                    DefinitionInfo(name: name, kind: "enum",
                                   lineRange: LineRange(index + 1, end + 1),
                                   fields: Self.members(in: view, from: index, to: end,
                                                        pattern: Self.enumValue))
                )
                continue
            }

            if let service = Self.serviceDecl.group(1, in: line) {
                let end = view.blockEnd(from: index)
                for bodyIndex in (index + 1)..<min(end, view.count) {
                    guard let rpc = Self.rpcDecl.group(1, in: view.trimmedCode(bodyIndex)) else {
                        continue
                    }
                    analysis.endpoints.append(
                        EndpointInfo(method: "rpc", path: "\(service).\(rpc)",
                                     lineRange: LineRange(bodyIndex + 1, bodyIndex + 1))
                    )
                }
            }
        }
        return analysis
    }

    private static func members(
        in view: SourceView, from start: Int, to end: Int, pattern: NSRegularExpression
    ) -> [String] {
        var out: [String] = []
        guard start + 1 <= end else { return [] }
        for index in (start + 1)..<min(end, view.count) where view.depthBefore[index] == 1 {
            if let name = pattern.group(1, in: view.trimmedCode(index)) { out.append(name) }
        }
        return out
    }
}

// MARK: - Terraform

struct TerraformParser: StructureExtractor {
    let languages = ["terraform"]
    var syntax: CommentSyntax {
        CommentSyntax(lineComment: ["#", "//"], blockComment: [(open: "/*", close: "*/")],
                      stringDelimiters: ["\""])
    }

    private static let resourceDecl = Rx.compile(#"^resource\s+"([^"]+)"\s+"([^"]+)""#)
    private static let dataDecl = Rx.compile(#"^data\s+"([^"]+)"\s+"([^"]+)""#)
    private static let moduleDecl = Rx.compile(#"^module\s+"([^"]+)""#)
    private static let variableDecl = Rx.compile(#"^variable\s+"([^"]+)""#)
    private static let outputDecl = Rx.compile(#"^output\s+"([^"]+)""#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in view.topLevelLines {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }
            let end = view.blockEnd(from: index)
            let range = LineRange(index + 1, end + 1)

            if let groups = Self.resourceDecl.firstGroups(in: line),
               let type = groups[group: 1],
               let name = groups[group: 2] {
                analysis.resources.append(
                    ResourceInfo(name: "\(type).\(name)", kind: type, lineRange: range)
                )
                continue
            }
            if let groups = Self.dataDecl.firstGroups(in: line),
               let type = groups[group: 1],
               let name = groups[group: 2] {
                analysis.resources.append(
                    ResourceInfo(name: "data.\(type).\(name)", kind: "data.\(type)", lineRange: range)
                )
                continue
            }
            if let name = Self.moduleDecl.group(1, in: line) {
                analysis.resources.append(
                    ResourceInfo(name: "module.\(name)", kind: "module", lineRange: range)
                )
                continue
            }
            if let name = Self.variableDecl.group(1, in: line) {
                analysis.definitions.append(
                    DefinitionInfo(name: name, kind: "variable", lineRange: range, fields: [])
                )
                continue
            }
            if let name = Self.outputDecl.group(1, in: line) {
                analysis.definitions.append(
                    DefinitionInfo(name: name, kind: "output", lineRange: range, fields: [])
                )
            }
        }
        return analysis
    }
}

// MARK: - Makefile

struct MakefileParser: StructureExtractor {
    let languages = ["makefile"]
    var syntax: CommentSyntax { .hashOnly }

    private static let target = Rx.compile(#"^([a-zA-Z_.][a-zA-Z0-9_.-]*)(?:\s+[^:]*)?:(?!=)"#)

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()

        for index in 0..<view.count {
            let raw = view.lines[index]
            // A recipe line starts with a tab; only rule lines start at column
            // zero.
            guard !raw.hasPrefix("\t"), !raw.hasPrefix(" ") else { continue }
            let line = view.trimmedCode(index)
            guard !line.isEmpty, !line.contains(":="), !line.contains("?=") else { continue }
            guard let name = Self.target.group(1, in: line), !name.hasPrefix(".") else { continue }

            // The recipe runs until the first line that is neither blank nor
            // indented.
            var end = index
            var probe = index + 1
            while probe < view.count {
                let next = view.lines[probe]
                if next.trimmingCharacters(in: .whitespaces).isEmpty {
                    probe += 1
                    continue
                }
                guard next.hasPrefix("\t") || next.hasPrefix("  ") else { break }
                end = probe
                probe += 1
            }
            analysis.steps.append(
                StepInfo(name: name, lineRange: LineRange(index + 1, end + 1))
            )
        }
        return analysis
    }
}

// MARK: - HTML and CSS

/// Light structural reading of markup.
///
/// Upstream registers no parser for these, so HTML and CSS files land in its
/// graph as bare nodes. Recording landmark elements and rule groups costs
/// almost nothing and makes a front-end project's graph noticeably less empty;
/// nothing here emits sub-file nodes, so the shape of the graph is unchanged.
struct HTMLCSSParser: StructureExtractor {
    let languages = ["html", "css"]
    var syntax: CommentSyntax {
        CommentSyntax(lineComment: [], blockComment: [(open: "<!--", close: "-->"),
                                                      (open: "/*", close: "*/")],
                      stringDelimiters: ["\"", "'"])
    }

    private static let htmlLandmark = Rx.compile(
        #"<(header|nav|main|section|article|aside|footer|form|table)\b[^>]*?(?:id=["']([^"']+)["'])?"#,
        options: [.caseInsensitive]
    )
    private static let cssRule = Rx.compile(#"^([.#]?[\w-][^{,]*?)\s*\{"#)
    private static let cssImport = Rx.compile(#"@import\s+(?:url\()?["']([^"')]+)["']"#)
    private static let htmlAsset = Rx.compile(
        #"(?:src|href)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]
    )

    func extract(_ view: SourceView, path: String) -> StructuralAnalysis {
        var analysis = StructuralAnalysis()
        let isCSS = ["css"].contains(LanguageRegistry.language(for: path))

        for index in 0..<view.count {
            let line = view.trimmedCode(index)
            guard !line.isEmpty else { continue }

            if isCSS {
                if let source = Self.cssImport.group(1, in: line) {
                    analysis.imports.append(
                        ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                    )
                    continue
                }
                guard view.depthBefore[index] == 0,
                      let selector = Self.cssRule.group(1, in: line) else { continue }
                analysis.sections.append(
                    SectionInfo(name: selector.trimmingCharacters(in: .whitespaces), level: 1,
                                lineRange: LineRange(index + 1, view.blockEnd(from: index) + 1))
                )
                continue
            }

            for groups in Self.htmlAsset.allGroups(in: view.lines[index]) {
                guard let source = groups[group: 1] else { continue }
                if source.hasPrefix("http") || source.hasPrefix("//") || source.hasPrefix("#")
                    || source.hasPrefix("data:") { continue }
                analysis.imports.append(
                    ImportInfo(source: source, specifiers: [], lineNumber: index + 1)
                )
            }
            if let groups = Self.htmlLandmark.firstGroups(in: view.lines[index]),
               let tag = groups[group: 1] {
                let id = groups[group: 2]
                analysis.sections.append(
                    SectionInfo(name: id.map { "\(tag)#\($0)" } ?? tag, level: 1,
                                lineRange: LineRange(index + 1, index + 1))
                )
            }
        }
        return analysis
    }
}
