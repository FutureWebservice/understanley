import Foundation

/// Groups files into architectural layers by directory convention.
///
/// Ported from upstream's `layer-detector.ts`. The loop nesting is the part
/// that matters and is easy to get wrong: the **pattern group is the outer
/// loop**, so a file at `src/api/services/user.ts` lands in the API layer, not
/// the Service layer — layer priority beats position in the path. Reversing the
/// loops silently reshuffles most of the graph.
enum LayerDetector {
    struct Pattern: Sendable {
        let segments: [String]
        let layerName: String
        let description: String
    }

    /// Evaluated in order; first match wins.
    static let patterns: [Pattern] = [
        Pattern(segments: ["routes", "controller", "handler", "endpoint", "api"],
                layerName: "API Layer",
                description: "HTTP endpoints, route handlers, and API controllers"),
        Pattern(segments: ["service", "usecase", "use-case", "business"],
                layerName: "Service Layer",
                description: "Business logic and application services"),
        Pattern(segments: ["model", "entity", "schema", "database", "db", "migration",
                           "repository", "repo"],
                layerName: "Data Layer",
                description: "Data models, database access, and persistence"),
        Pattern(segments: ["component", "view", "page", "screen", "layout", "widget", "ui"],
                layerName: "UI Layer",
                description: "User interface components and views"),
        Pattern(segments: ["middleware", "interceptor", "guard", "filter", "pipe"],
                layerName: "Middleware Layer",
                description: "Request/response middleware and interceptors"),
        Pattern(segments: ["client", "integration", "external", "sdk", "vendor", "adapter"],
                layerName: "External Services",
                description: "External service integrations, SDKs, and third-party adapters"),
        Pattern(segments: ["worker", "job", "queue", "cron", "consumer", "processor",
                           "scheduler", "background"],
                layerName: "Background Tasks",
                description: "Background workers, job processors, and scheduled tasks"),
        Pattern(segments: ["util", "helper", "lib", "common", "shared"],
                layerName: "Utility Layer",
                description: "Shared utilities, helpers, and common libraries"),
        Pattern(segments: ["test", "spec", "__test__", "__spec__", "__tests__", "__specs__"],
                layerName: "Test Layer",
                description: "Test files and test utilities"),
        Pattern(segments: ["config", "setting", "env"],
                layerName: "Configuration Layer",
                description: "Application configuration and environment settings"),
    ]

    static let coreLayerName = "Core"
    static let coreDescription = "Core application files"

    /// The layer a path belongs to, or nil for none.
    ///
    /// A path segment must equal a pattern exactly, or that pattern plus `s` —
    /// so a directory called `apis/` matches `api` but a file called `api.ts`
    /// does not, because its segment is `api.ts`.
    static func layerName(for filePath: String) -> String? {
        let normalized = PosixPath.normalize(filePath).lowercased()
        let segments = normalized.split(separator: "/").map(String.init)

        for pattern in patterns {
            for segment in segments {
                for candidate in pattern.segments
                where segment == candidate || segment == candidate + "s" {
                    return pattern.layerName
                }
            }
        }
        return nil
    }

    /// Assigns every file-level node to exactly one layer.
    ///
    /// Only file-level nodes participate — functions and classes are reached
    /// through their containing file. Nodes matching nothing go to `Core`, and
    /// nodes without a path go there too, appended last so ordering stays
    /// deterministic.
    static func detect(nodes: [GraphNode]) -> [Layer] {
        // Insertion-ordered accumulation: layers appear in the order they are
        // first needed, which keeps the overview stable between runs.
        var order: [String] = []
        var members: [String: [String]] = [:]
        var pathless: [String] = []

        for node in nodes where NodeType.fileLevel.contains(node.type) {
            guard let path = node.filePath, !path.isEmpty else {
                pathless.append(node.id)
                continue
            }
            let name = layerName(for: path) ?? coreLayerName
            if members[name] == nil {
                members[name] = []
                order.append(name)
            }
            members[name]?.append(node.id)
        }

        if !pathless.isEmpty {
            if members[coreLayerName] == nil {
                members[coreLayerName] = []
                order.append(coreLayerName)
            }
            members[coreLayerName]?.append(contentsOf: pathless)
        }

        return order.map { name in
            Layer(
                id: "layer:" + name.lowercased().replacingOccurrences(of: " ", with: "-"),
                name: name,
                description: name == coreLayerName
                    ? coreDescription
                    : (patterns.first { $0.layerName == name }?.description ?? ""),
                nodeIds: members[name] ?? []
            )
        }
    }
}
