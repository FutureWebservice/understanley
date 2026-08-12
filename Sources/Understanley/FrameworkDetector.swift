import Foundation

/// Detects frameworks by looking for keywords in dependency manifests.
///
/// Ported from upstream's `framework-registry.ts`, including its imprecision.
/// Matching is a plain lowercase substring test with no word boundaries, so
/// `react` matches any `package.json` mentioning React anywhere — including one
/// that merely depends on `react-is`. Upstream works around this for the
/// frameworks where it matters by using a quoted-key form (`"next":`,
/// `"express":`), and those exact spellings are preserved here. Loosening or
/// tightening the rules would change which frameworks a project reports, and
/// that string ends up in the graph's project metadata.
enum FrameworkDetector {
    struct Framework: Sendable {
        let id: String
        /// Display name shown in the UI.
        let name: String
        let languages: [String]
        let manifestFiles: [String]
        let detectionKeywords: [String]
        /// Conventional entry points, most specific first. Used to seed the
        /// guided tour.
        let entryPoints: [String]
    }

    /// Evaluation order matters only for reporting; every matching framework is
    /// reported, not just the first.
    static let all: [Framework] = [
        Framework(
            id: "django", name: "Django", languages: ["python"],
            manifestFiles: ["requirements.txt", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile"],
            detectionKeywords: ["django", "djangorestframework", "django-rest-framework",
                                "django-cors-headers", "django-filter"],
            entryPoints: ["manage.py", "wsgi.py", "asgi.py"]
        ),
        Framework(
            id: "fastapi", name: "FastAPI", languages: ["python"],
            manifestFiles: ["requirements.txt", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile"],
            detectionKeywords: ["fastapi", "uvicorn", "starlette"],
            entryPoints: ["main.py", "app/main.py", "src/main.py"]
        ),
        Framework(
            id: "flask", name: "Flask", languages: ["python"],
            manifestFiles: ["requirements.txt", "pyproject.toml", "setup.py", "setup.cfg", "Pipfile"],
            detectionKeywords: ["flask", "flask-restful", "flask-sqlalchemy",
                                "flask-marshmallow", "flask-wtf"],
            entryPoints: ["app.py", "wsgi.py", "run.py"]
        ),
        Framework(
            id: "react", name: "React", languages: ["typescript", "javascript"],
            manifestFiles: ["package.json"],
            detectionKeywords: ["react", "react-dom", "@types/react"],
            entryPoints: ["src/main.tsx", "src/index.tsx", "src/App.tsx", "src/index.js"]
        ),
        Framework(
            id: "nextjs", name: "Next.js", languages: ["typescript", "javascript"],
            manifestFiles: ["package.json"],
            // Quoted key on purpose: a bare `next` would match `next-auth`,
            // `next-themes`, and half of npm.
            detectionKeywords: ["\"next\":", "@next/font", "@next/image"],
            entryPoints: ["app/page.tsx", "app/layout.tsx", "pages/_app.tsx", "pages/index.tsx"]
        ),
        Framework(
            id: "express", name: "Express", languages: ["javascript", "typescript"],
            manifestFiles: ["package.json"],
            detectionKeywords: ["\"express\":", "express-validator", "express-session"],
            entryPoints: ["src/index.ts", "src/app.ts", "index.js", "app.js", "server.js"]
        ),
        Framework(
            id: "vue", name: "Vue", languages: ["typescript", "javascript"],
            manifestFiles: ["package.json"],
            detectionKeywords: ["vue", "@vue/cli-service", "nuxt", "vite-plugin-vue"],
            entryPoints: ["src/main.ts", "src/main.js", "src/App.vue"]
        ),
        Framework(
            id: "spring", name: "Spring", languages: ["java", "kotlin"],
            manifestFiles: ["pom.xml", "build.gradle", "build.gradle.kts"],
            detectionKeywords: ["spring-boot", "spring-boot-starter", "spring-web",
                                "spring-data", "org.springframework"],
            entryPoints: ["Application.java", "Application.kt"]
        ),
        Framework(
            id: "rails", name: "Rails", languages: ["ruby"],
            manifestFiles: ["Gemfile"],
            detectionKeywords: ["rails", "railties", "actionpack", "activerecord", "actionview"],
            entryPoints: ["config.ru", "config/application.rb"]
        ),
        Framework(
            id: "gin", name: "Gin", languages: ["go"],
            manifestFiles: ["go.mod"],
            detectionKeywords: ["github.com/gin-gonic/gin"],
            entryPoints: ["main.go", "cmd/main.go"]
        ),
    ]

    /// Every manifest filename any framework cares about — the scanner only
    /// needs to read these, not every config file in the tree.
    static let allManifestFilenames: Set<String> = Set(all.flatMap(\.manifestFiles))

    /// Returns the display names of every detected framework.
    ///
    /// - Parameter manifests: project-relative path → file contents, for files
    ///   whose basename appears in `allManifestFilenames`.
    static func detect(manifests: [String: String]) -> [String] {
        // Lowercase once per manifest rather than once per keyword — a large
        // `pom.xml` checked against five frameworks would otherwise be
        // lowercased fifteen times.
        let lowered = manifests.mapValues { $0.lowercased() }

        var found: [String] = []
        for framework in all {
            for manifestFile in framework.manifestFiles {
                guard let contents = contents(for: manifestFile, in: lowered) else { continue }
                let matched = framework.detectionKeywords.contains {
                    contents.contains($0.lowercased())
                }
                if matched {
                    found.append(framework.name)
                }
                // First manifest that exists decides, whether or not it matched.
                break
            }
        }
        return found
    }

    /// Finds a manifest by exact path or by `<dir>/<name>` suffix, so a
    /// `package.json` nested in a monorepo package still counts.
    private static func contents(for manifestFile: String, in manifests: [String: String]) -> String? {
        if let exact = manifests[manifestFile] { return exact }
        let suffix = "/" + manifestFile
        // Sorted so the choice is deterministic when several packages in a
        // monorepo each have one.
        for key in manifests.keys.sortedStable() where key.hasSuffix(suffix) {
            return manifests[key]
        }
        return nil
    }

    // MARK: - Entry point

    /// Conventional entry points checked in order when no framework supplies
    /// one. Ported from upstream's `/understand` Phase 0.
    static let genericEntryPoints: [String] = [
        "src/index.ts", "src/main.ts", "src/App.tsx", "index.js",
        "main.py", "manage.py", "app.py", "wsgi.py", "asgi.py", "run.py", "__main__.py",
        "main.go",
        "src/main.rs", "src/lib.rs",
        "Program.cs",
        "config.ru",
        "index.php",
        "Sources/main.swift",
    ]

    /// Picks the project's entry point: framework conventions first, then the
    /// generic list, then a `cmd/*/main.go` scan for Go layouts that put the
    /// binary under a subdirectory.
    ///
    /// Returns nil when nothing conventional exists — a library, most likely.
    /// The tour generator falls back to graph topology in that case rather than
    /// guessing.
    static func entryPoint(in paths: Set<String>, frameworks: [String]) -> String? {
        let detected = Set(frameworks)
        for framework in all where detected.contains(framework.name) {
            for candidate in framework.entryPoints {
                if paths.contains(candidate) { return candidate }
                // Framework entry points are often nested (`Application.java`
                // lives deep under `src/main/java/...`).
                if let match = paths.first(where: { $0.hasSuffix("/" + candidate) }) { return match }
            }
        }

        for candidate in genericEntryPoints where paths.contains(candidate) {
            return candidate
        }

        let goMains = paths.filter { $0.hasPrefix("cmd/") && $0.hasSuffix("/main.go") }
        if let first = goMains.sortedStable().first { return first }

        return nil
    }
}
