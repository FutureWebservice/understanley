import SwiftUI

/// The main working view: canvas on the left, inspector on the right.
struct ProjectView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = GraphViewModel()

    @State private var searchText = ""
    @State private var searchEngine: SearchEngine?
    /// Which result the arrow keys are sitting on, or nil before any movement.
    @State private var searchCursor: Int?
    @FocusState private var searchFocused: Bool
    @State private var showSidebar = true
    @State private var showSettings = false
    @State private var askTarget: AskTarget?
    @State private var showExport = false
    @State private var exportError: String?
    @State private var showShortcuts = false
    @State private var showFilters = false
    @State private var showIgnoreEditor = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    /// Path of the file open in the code viewer, if any.
    @State private var openFile: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                // Painted last, so the search results overlay is not covered by
                // the canvas below it — later siblings win the depth order.
                .zIndex(1)
            Divider().overlay(Theme.borderSubtle)
            StalenessBanner(model: model)
            enrichmentErrorBanner

            if showFilters { filterBar }
            if let message = model.pathMessage { pathBar(message) }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    GraphCanvas(model: model)
                    if let openFile {
                        CodeViewer(
                            projectRoot: store.projectRoot ?? "",
                            allowedPaths: readablePaths,
                            path: openFile,
                            highlight: highlightRange(for: openFile),
                            onClose: { self.openFile = nil }
                        )
                        .transition(.move(edge: .bottom))
                    }
                }

                if showSidebar {
                    Divider().overlay(Theme.borderSubtle)
                    SidebarView(model: model, onOpenFile: { openFile = $0 })
                        .frame(width: 360)
                        .background(Theme.panel)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Theme.root)
        .overlay {
            if !hasSeenOnboarding, store.hasGraph, !store.isAnalyzing {
                OnboardingOverlay {
                    withAnimation(.easeOut(duration: 0.2)) { hasSeenOnboarding = true }
                }
            }
        }
        .sheet(isPresented: $showIgnoreEditor) {
            IgnoreEditorView().environmentObject(store)
        }
        .onAppear { loadGraph() }
        .onChange(of: store.graph?.project.gitCommitHash) { _ in loadGraph() }
        .onChange(of: store.changedFiles) { files in
            guard let graph = store.graph else { return }
            model.setChangedFiles(files, graph: graph)
        }
        .onChange(of: model.isLayingOut) { laying in
            // The overlay needs the compiled arrays, so it can only be built
            // once layout has finished — git may well have answered first.
            guard !laying, let graph = store.graph else { return }
            model.setChangedFiles(store.changedFiles, graph: graph)
        }
        .onChange(of: searchText) { runSearch($0) }
        .onKeyStroke(handleKey)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store)
        }
        .confirmationDialog("Export", isPresented: $showExport, titleVisibility: .visible) {
            ForEach(ExportService.Format.allCases) { format in
                Button(format.label) { runExport(format) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a format.")
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showShortcuts) { ShortcutsHelp() }
        .sheet(item: $askTarget) { target in
            AskPanel(model: model, searchEngine: searchEngine, explainNodeID: target.nodeID)
                .environmentObject(store)
        }
    }

    /// What the ask panel opens onto: a free-form question, or one node.
    /// Modelled as an item rather than a boolean so the two cannot collide.
    struct AskTarget: Identifiable {
        var id: String { nodeID ?? "__ask__" }
        var nodeID: String?
    }

    private func loadGraph() {
        guard let graph = store.graph else { return }
        searchEngine = SearchEngine(graph: graph)
        model.load(graph, entryPoint: nil)
    }

    private func runExport(_ format: ExportService.Format) {
        guard let graph = store.graph else { return }
        exportError = ExportService.run(
            format, graph: graph, arrays: model.arrays, positions: model.displayPositions
        )
    }

    private func runSearch(_ query: String) {
        guard let searchEngine else { return }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            model.clearSearch()
            return
        }
        let hits = searchEngine.search(query)
        model.setSearchResults(hits.map { (index: $0.index, score: $0.score) })
        searchCursor = nil
    }

    /// Moves the highlight through the result list and flies the camera there.
    ///
    /// Counting matches was never the point — reaching them is. Arrow keys
    /// rather than a click-only list, because search is a keyboard activity and
    /// the results sit directly under the field the user is already typing in.
    /// Opens the selected node's file in the viewer.
    private func openSelectedFile() {
        guard let index = model.selected, index < model.arrays.count,
              let node = store.graph?.nodes.first(where: { $0.id == model.arrays.ids[index] }),
              let path = node.filePath else { return }
        withAnimation(.easeInOut(duration: 0.18)) { openFile = path }
    }

    private func moveSearchCursor(by delta: Int) {
        let hits = model.searchHits
        guard !hits.isEmpty else { return }
        let next = ((searchCursor ?? -1) + delta + hits.count) % hits.count
        searchCursor = next
        model.select(hits[next])
        model.focusCamera(on: hits[next])
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.searchHits.prefix(8).enumerated()), id: \.element) { position, index in
                Button {
                    searchCursor = position
                    model.select(index)
                    model.focusCamera(on: index)
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Theme.color(for: model.arrays.types[index]))
                            .frame(width: 6, height: 6)
                        Text(model.arrays.names[index])
                            .font(.callout)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(model.arrays.types[index].rawValue)
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        searchCursor == position ? Theme.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if model.searchHits.count > 8 {
                Text("+\(model.searchHits.count - 8) more — ↑↓ to step through all")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .padding(4)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Theme.borderSubtle, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.projectName)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                Text("\(model.arrays.count) nodes · \(model.arrays.edgeCount) edges")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .frame(width: 200, alignment: .leading)

            modeToggle

            searchField
                .overlay(alignment: .topLeading) {
                    if !searchText.isEmpty, !model.searchHits.isEmpty {
                        searchResults.offset(y: 34)
                    }
                }

            Spacer(minLength: 8)

            enrichmentControl

            controlButton("scope", "Fit to screen", "0") {
                model.fitAll()
            }
            controlButton(
                model.focused == nil ? "circle.dashed" : "circle.dashed.inset.filled",
                model.focused == nil ? "Focus on selection" : "Clear focus", "f"
            ) {
                model.toggleFocus()
            }
            .disabled(model.selected == nil && model.focused == nil)

            if !model.diff.isEmpty {
                controlButton(
                    model.diffMode ? "circle.lefthalf.filled" : "circle.righthalf.filled",
                    model.diffMode ? "Stop highlighting changes" : "Highlight what changed", "d"
                ) {
                    model.toggleDiff()
                }
            }
            controlButton("square.and.arrow.up", "Export this graph", "e") {
                showExport = true
            }
            controlButton("bubble.left.and.text.bubble.right", "Ask about this codebase", "a") {
                askTarget = AskTarget(nodeID: nil)
            }
            controlButton("gearshape", "AI enrichment settings", ",") {
                showSettings = true
            }
            controlButton("sidebar.right", showSidebar ? "Hide inspector" : "Show inspector", "i") {
                withAnimation(.easeInOut(duration: 0.18)) { showSidebar.toggle() }
            }
            controlButton("arrow.clockwise", "Re-analyze this project", "r") {
                store.analyze()
            }
            controlButton("xmark", "Close project", "w") {
                model.cancel()
                store.closeProject()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    /// Enrichment status and trigger.
    ///
    /// Always visible rather than hidden in a menu, because "these nodes have
    /// no summary yet" is a real state of the graph the user should be able to
    /// see and act on in one click.
    /// Shown when a describe run produced nothing.
    ///
    /// A banner rather than a full-screen error: the graph is still perfectly
    /// good — the deterministic half of this app never needed a model — so
    /// losing the whole view because a CLI is signed out would be absurd.
    /// Every path the code viewer is allowed to open — exactly the files this
    /// graph describes, and nothing else on the disk.
    private var readablePaths: Set<String> {
        guard let graph = store.graph else { return [] }
        return Set(graph.nodes.compactMap(\.filePath))
    }

    /// The selected node's own line span, so the viewer opens on it.
    private func highlightRange(for path: String) -> LineRange? {
        guard let index = model.selected, index < model.arrays.count,
              let node = store.graph?.nodes.first(where: { $0.id == model.arrays.ids[index] }),
              node.filePath == path else { return nil }
        return node.lineRange
    }

    /// Category filter chips. Hiding whole categories is the fastest way to
    /// make a busy graph readable — on a typical project the 40 function nodes
    /// outnumber the 42 files and bury them.
    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(model.categoryCounts(), id: \.0) { category, count in
                let hidden = model.hiddenCategories.contains(category)
                Button {
                    model.toggleCategory(category)
                } label: {
                    HStack(spacing: 5) {
                        Text(category.rawValue.capitalized).font(.caption)
                        Text("\(count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(
                        hidden ? Color.clear : Theme.accent.opacity(0.16),
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(Theme.borderSubtle, lineWidth: hidden ? 1 : 0))
                    .foregroundStyle(hidden ? Theme.textMuted : Theme.textPrimary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(hidden ? "Show \(category.rawValue) nodes" : "Hide \(category.rawValue) nodes")
            }
            Spacer(minLength: 8)
            if !model.hiddenCategories.isEmpty {
                Button("Show all") { model.clearFilters() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
            Button { withAnimation { showFilters = false } } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.borderSubtle) }
    }

    private func pathBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption).foregroundStyle(Theme.accent)
            Text(message).font(.caption).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button("Clear") { model.clearPath() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.accent.opacity(0.07))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.borderSubtle) }
    }

    @ViewBuilder private var enrichmentErrorBanner: some View {
        if let message = store.enrichmentError {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.diffAffected)
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Settings") { showSettings = true }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .help("Choose a different provider, or add an API key.")
                Button {
                    store.dismissEnrichmentError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.diffAffected.opacity(0.09))
            .overlay(alignment: .bottom) { Divider().overlay(Theme.borderSubtle) }
        }
    }

    @ViewBuilder private var enrichmentControl: some View {
        if store.isEnriching {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                if let progress = store.enrichmentProgress {
                    Text(progress.message)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Button {
                    store.cancelEnrichment()
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Stop describing. Everything already described is kept.")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7))
        } else if store.undescribedCount > 0 {
            Button {
                if store.activeProviderSpec == nil { showSettings = true } else { store.enrich() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text(store.activeProviderSpec == nil
                         ? "Add summaries…"
                         : "Describe \(store.undescribedCount)")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentBright)
            .help(store.activeProviderSpec == nil
                  ? "Set up an AI provider to add plain-English summaries. Entirely optional."
                  : "Describe the \(store.undescribedCount) nodes that have no summary, "
                    + "using \(store.activeProviderSpec?.displayName ?? "")")
        }
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases, id: \.self) { candidate in
                Button {
                    withAnimation(nil) { model.mode = candidate }
                } label: {
                    Text(candidate.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            model.mode == candidate ? Theme.accent.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(model.mode == candidate ? Theme.accentBright : Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help(candidate == .blueprint
                      ? "Layered architectural view (u)"
                      : "Force-directed view — colour shows layer and type (u)")
            }
        }
        .padding(2)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            TextField("Search  ⌘F", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Text("\(model.searchHits.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 260)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderSubtle, lineWidth: 1))
    }

    private func controlButton(
        _ symbol: String, _ help: String, _ key: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7))
        .help("\(help)  (\(key))")
    }

    // MARK: - Keyboard

    private func handleKey(_ stroke: KeyStroke) -> Bool {
        if stroke.isEscape {
            // Priority chain, most specific first, so one key reliably backs
            // out of whatever is deepest.
            if !searchText.isEmpty { searchText = ""; searchFocused = false }
            else if searchFocused { searchFocused = false }
            else if openFile != nil { openFile = nil }
            else if model.pathMessage != nil { model.clearPath() }
            else if model.tourStep != nil { model.stopTour() }
            else if model.focused != nil { model.toggleFocus() }
            else if model.selected != nil { model.select(nil) }
            return true
        }
        // Search results take the arrow keys while a query is live: the list is
        // right under the field, and stepping through matches is what the user
        // is trying to do. Everything else keeps its meaning.
        if !searchText.isEmpty, !model.searchHits.isEmpty {
            if stroke.isDownArrow { moveSearchCursor(by: 1); return true }
            if stroke.isUpArrow { moveSearchCursor(by: -1); return true }
            if stroke.isReturn {
                if searchCursor == nil { moveSearchCursor(by: 1) }
                searchText = ""
                return true
            }
        }
        // ⌘F before the plain-key gate. "/" is a fine accelerator on a US
        // layout and useless on most others — on a German keyboard it is
        // Shift+7 — so the platform-standard Find shortcut is the one that has
        // to work everywhere.
        if stroke.hasCommand, stroke.character == "f" {
            searchFocused = true
            return true
        }
        // Left/right walk the tour once it is running. Up/down already belong
        // to the search list, so the two never compete for the same key.
        if let current = model.tourStep, let tour = store.graph?.tour, !tour.isEmpty {
            if stroke.isRightArrow { model.playTour(tour, step: current + 1); return true }
            if stroke.isLeftArrow { model.playTour(tour, step: current - 1); return true }
        }
        guard stroke.isPlain else { return false }

        switch stroke.character {
        case "/":
            // The placeholder has always said "Search /". Until now that was a
            // promise the app did not keep — the key did nothing, and the
            // letters that followed fell through to the single-key shortcuts.
            searchFocused = true
        case "u":
            model.mode = model.mode.other
        case "0":
            model.fitAll()
        case "f":
            model.toggleFocus()
        case "i":
            withAnimation(.easeInOut(duration: 0.18)) { showSidebar.toggle() }
        case ",":
            showSettings = true
        case "t":
            if let tour = store.graph?.tour, !tour.isEmpty {
                if model.tourStep == nil { model.playTour(tour, step: 0) } else { model.stopTour() }
            }
        case "x":
            showIgnoreEditor = true
        case "l":
            withAnimation(.easeInOut(duration: 0.15)) { showFilters.toggle() }
        case "p":
            model.markPathEndpoint(model.selected)
        case "o" where model.selected != nil:
            openSelectedFile()
        case "d":
            model.toggleDiff()
        case "a":
            askTarget = AskTarget(nodeID: nil)
        case "e" where model.selected == nil:
            showExport = true
        case "?":
            showShortcuts = true
        case "e":
            // With a selection `e` explains it; without one there is nothing to
            // explain, so it exports instead.
            guard let selected = model.selected, selected < model.arrays.count else { return false }
            askTarget = AskTarget(nodeID: model.arrays.ids[selected])
        default:
            return false
        }
        return true
    }
}
