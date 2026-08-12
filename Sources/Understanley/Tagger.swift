import Foundation

/// Assigns the keyword tags shown on every node.
///
/// Upstream asks the LLM for 3–5 lowercase hyphenated tags and gives it a list
/// of indicators to look for. Almost all of those indicators are mechanical —
/// "named `index.ts` with re-exports is a barrel", "`.github/workflows/*` is
/// ci-cd" — so they are computed here instead. Tags then exist before any model
/// runs, and enrichment refines rather than creates them.
enum Tagger {
    /// Tags for a file node.
    static func tags(for file: ScannedFile, analysis: StructuralAnalysis, nodeType: NodeType) -> [String] {
        var tags: [String] = []
        let posix = PosixPath.normalize(file.path)
        let base = PosixPath.basename(posix)
        let ext = PosixPath.fileExtension(posix)
        let lowerBase = base.lowercased()

        func add(_ tag: String) {
            guard !tags.contains(tag), tags.count < 5 else { return }
            tags.append(tag)
        }

        // ── Tests come first: it is the single most useful thing to know
        //    about a file, and it changes how everything else reads.
        if TestLinker.isTestPath(posix) { add("test") }

        // ── Entry points, by the conventions of each ecosystem.
        if isEntryPoint(posix, base: base) { add("entry-point") }

        // ── Barrels: lots of re-exports, little of its own.
        let reexportCount = analysis.imports.filter { !$0.specifiers.isEmpty }.count
        if (base.hasPrefix("index.") || base == "mod.rs" || base == "__init__.py"),
           analysis.functions.count + analysis.classes.count <= 1, reexportCount > 0 {
            add("barrel")
        }

        // ── Role, inferred from what the file declares.
        let declaredNames = analysis.classes.map(\.name) + analysis.functions.map(\.name)
        if declaredNames.contains(where: { $0.hasSuffix("Handler") || $0.hasSuffix("Controller") }) {
            add("api-handler")
        }
        if declaredNames.contains(where: { $0.hasSuffix("Service") }) { add("service") }
        if declaredNames.contains(where: { $0.hasSuffix("Repository") || $0.hasSuffix("Repo") }) {
            add("data-model")
        }
        if declaredNames.contains(where: { $0.hasPrefix("use") && $0.count > 3 }) { add("hook") }
        if !analysis.endpoints.isEmpty { add("api-schema") }

        // A TypeScript file that only exports types has no runtime presence.
        if (ext == ".ts" || ext == ".d.ts"), analysis.functions.isEmpty,
           !analysis.classes.isEmpty, analysis.classes.allSatisfy({ $0.methods.isEmpty }) {
            add("type-definition")
        }

        // ── Category-driven tags.
        switch nodeType {
        case .document:
            add("documentation")
            if lowerBase.hasPrefix("readme") { add("overview") }
            if lowerBase.hasPrefix("contributing") { add("development") }
            if lowerBase.hasPrefix("changelog") { add("release-notes") }
        case .config:
            add("configuration")
            if base == "package.json" || base == "Cargo.toml" || base == "go.mod"
                || base == "pyproject.toml" { add("build-system") }
            if lowerBase.hasPrefix(".env") { add("security") }
        case .service:
            add("infrastructure")
            if base.hasPrefix("Dockerfile") { add("containerization") }
            if base.hasPrefix("docker-compose") || base.hasPrefix("compose.") {
                add("orchestration")
            }
            if !analysis.services.isEmpty { add("deployment") }
        case .pipeline:
            add("ci-cd")
            add("deployment")
        case .resource:
            add("infrastructure")
            if ext == ".tf" || ext == ".tfvars" { add("deployment") }
        case .table:
            add("database")
            if posix.contains("migration") { add("migration") }
        case .schema:
            add("schema-definition")
            if ext == ".graphql" || ext == ".gql" { add("api-schema") }
            if ext == ".proto" { add("data-pipeline") }
        case .endpoint:
            add("api-schema")
        case .file:
            break
        default:
            break
        }

        // ── Language, so the filter chips are useful even on an unenriched
        //    graph. Added late so it never crowds out a semantic tag.
        if file.fileCategory == .code || file.fileCategory == .script {
            add(file.language)
        }
        if tags.count < 2 { add(file.fileCategory.rawValue) }
        if tags.isEmpty { add("untagged") }
        return tags
    }

    /// Tags for a function node.
    static func tags(forFunction fn: FunctionInfo, exported: Bool) -> [String] {
        var tags: [String] = []
        let name = fn.name

        if exported { tags.append("exported") }
        if name.hasPrefix("use"), name.count > 3, name.dropFirst(3).first?.isUppercase == true {
            tags.append("hook")
        }
        if name.hasPrefix("test") || name.hasPrefix("Test") { tags.append("test") }
        if name.hasPrefix("handle") || name.hasSuffix("Handler") { tags.append("event-handler") }
        if name.hasPrefix("validate") || name.hasPrefix("is") || name.hasPrefix("has") {
            tags.append("validation")
        }
        if name.hasPrefix("create") || name.hasPrefix("make") || name.hasPrefix("build") {
            tags.append("factory")
        }
        if name.hasPrefix("parse") || name.hasPrefix("serialize") || name.hasPrefix("format")
            || name.hasPrefix("encode") || name.hasPrefix("decode") {
            tags.append("serialization")
        }
        if fn.lineRange.lineCount > 60 { tags.append("complex") }
        if tags.count < 2 { tags.append("function") }
        return Array(tags.prefix(5))
    }

    /// Tags for a class node.
    static func tags(forClass cls: ClassInfo, exported: Bool) -> [String] {
        var tags: [String] = []
        let name = cls.name

        if exported { tags.append("exported") }
        if name.hasSuffix("Controller") || name.hasSuffix("Handler") { tags.append("api-handler") }
        else if name.hasSuffix("Service") { tags.append("service") }
        else if name.hasSuffix("Repository") || name.hasSuffix("Repo") || name.hasSuffix("Model") {
            tags.append("data-model")
        }
        else if name.hasSuffix("Factory") || name.hasSuffix("Builder") { tags.append("factory") }
        else if name.hasSuffix("Error") || name.hasSuffix("Exception") {
            tags.append("error-handling")
        }
        else if name.hasSuffix("View") || name.hasSuffix("Component") { tags.append("component") }

        if cls.methods.isEmpty, !cls.properties.isEmpty { tags.append("type-definition") }
        if cls.methods.count > 12 { tags.append("complex") }
        if tags.count < 2 { tags.append("class") }
        return Array(tags.prefix(5))
    }

    // MARK: - Entry points

    private static func isEntryPoint(_ posix: String, base: String) -> Bool {
        switch base {
        case "manage.py", "config.ru", "Program.cs", "main.go", "__main__.py",
             "Application.java", "Main.java", "Application.kt":
            return true
        case "main.rs", "lib.rs":
            return posix.hasPrefix("src/")
        case "main.swift":
            return true
        default:
            break
        }
        // A root-level index or main file in a source directory.
        if base.hasPrefix("index.") || base.hasPrefix("main.") || base.hasPrefix("app.") {
            let depth = posix.split(separator: "/").count
            return depth <= 2
        }
        if posix.hasPrefix("cmd/"), base == "main.go" { return true }
        return false
    }
}
