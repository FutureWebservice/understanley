import SwiftUI

@main
struct UnderstanleyApp: App {
    @StateObject private var store = Store()

    init() {
        // CLI modes. These run the real pipeline with no window, which is what
        // CI smoke-tests and what makes the analyzer verifiable long before the
        // UI exists. Same pattern as AgentShare's `--scan-test`.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--analyze") {
            let path = idx + 1 < args.count ? args[idx + 1] : FileManager.default.currentDirectoryPath
            CLI.runAnalyze(path: path)
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--layout") {
            let path = idx + 1 < args.count ? args[idx + 1] : FileManager.default.currentDirectoryPath
            CLI.runLayout(path: path)
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--enrich"), idx + 1 < args.count {
            func flag(_ name: String) -> String? {
                guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            CLI.runEnrich(
                path: args[idx + 1],
                providerID: flag("--provider") ?? "ollama",
                model: flag("--model"),
                limit: flag("--limit").flatMap(Int.init) ?? 12
            )
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--export"), idx + 2 < args.count {
            CLI.runExport(path: args[idx + 1], outputDirectory: args[idx + 2])
            Foundation.exit(0)
        }
        if let idx = args.firstIndex(of: "--inspect"), idx + 2 < args.count {
            CLI.runInspect(root: args[idx + 1], relativePath: args[idx + 2])
            Foundation.exit(0)
        }
        if args.contains("--version") {
            print("Understanley 0.1.0")
            Foundation.exit(0)
        }
        if let i = args.firstIndex(of: "--ondevice-probe"), i + 1 < args.count {
            CLI.runOnDeviceProbe(
                user: args[i + 1],
                system: args.count > i + 2 ? args[i + 2] : "You are a precise code analyst."
            )
            Foundation.exit(0)
        }
        if let i = args.firstIndex(of: "--domains"), i + 1 < args.count {
            func flag(_ name: String) -> String? {
                guard let j = args.firstIndex(of: name), j + 1 < args.count else { return nil }
                return args[j + 1]
            }
            CLI.runDomains(
                path: args[i + 1],
                providerID: flag("--provider") ?? "apple-foundation",
                model: flag("--model")
            )
            Foundation.exit(0)
        }
        if args.contains("--help") || args.contains("-h") {
            CLI.printUsage()
            Foundation.exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Nothing here is document-based, so File ▸ New is misleading —
            // but File ▸ Open is exactly what a Mac user reaches for, and ⌘O
            // has to work. Recents belong in the same menu for the same reason.
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { store.chooseProject() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(store.recentProjects, id: \.self) { path in
                        Button(PosixPath.basename(path)) { store.open(path) }
                    }
                    if !store.recentProjects.isEmpty {
                        Divider()
                        Button("Clear Menu") { store.clearRecents() }
                    }
                }
                .disabled(store.recentProjects.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Reanalyze") { store.analyze() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.projectRoot == nil)
                Button("Close Project") { store.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(store.projectRoot == nil)
            }
        }
    }
}
