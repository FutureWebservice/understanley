import AppKit
import SwiftUI

/// The inspector. Shows the project until a node is selected, then that node.
///
/// Deliberately one panel rather than a tab bar: at any moment there is exactly
/// one thing you are looking at, and making the user choose which pane to be in
/// is a decision the app can make for them.
struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var model: GraphViewModel
    var onOpenFile: (String) -> Void = { _ in }

    /// Info answers "what is this"; Files answers "where does it live". They
    /// are different questions, and a folder tree cannot be folded into an
    /// inspector without one of them losing.
    enum Tab: String, CaseIterable { case info = "Info", files = "Files" }
    @State private var tab: Tab = .info

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Divider().overlay(Theme.borderSubtle)

            switch tab {
            case .info:
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let selected = model.selected, selected < model.arrays.count {
                            NodeInspector(onOpenFile: onOpenFile, model: model, index: selected)
                        } else {
                            ProjectOverview(model: model)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            case .files:
                FileExplorerView(model: model, onOpen: onOpenFile)
            }
        }
    }
}

// MARK: - Project overview

private struct ProjectOverview: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var model: GraphViewModel

    var body: some View {
        let arrays = model.arrays

        Group {
            if let graph = store.graph {
                section("Project") {
                    Text(graph.project.name)
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                    if !graph.project.description.isEmpty {
                        Text(graph.project.description)
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !graph.project.languages.isEmpty {
                        pills(graph.project.languages, tint: Theme.accent)
                    }
                    if !graph.project.frameworks.isEmpty {
                        pills(graph.project.frameworks, tint: Theme.tested)
                    }
                }

                section("At a glance") {
                    statGrid(graph)
                }

                if !arrays.layerNames.isEmpty {
                    section("Layers") {
                        ForEach(Array(arrays.layerNames.enumerated()), id: \.offset) { index, name in
                            layerRow(index: index, name: name)
                        }
                    }
                }

                section("Domains") { domainSection }

                if !graph.tour.isEmpty {
                    section("Where to start") {
                        tourControls(graph.tour)
                        // Every step, not the first four. A tour that stops
                        // two thirds of the way through is not a tour.
                        ForEach(Array(graph.tour.enumerated()), id: \.element.order) { position, step in
                            tourRow(step, position: position, tour: graph.tour)
                        }
                    }
                }

                if !store.diagnostics.isEmpty {
                    section("Diagnostics") {
                        diagnosticsSummary
                    }
                }
            }
        }
    }

    private func statGrid(_ graph: KnowledgeGraph) -> some View {
        let files = graph.nodes.filter { NodeType.fileLevel.contains($0.type) }.count
        let functions = graph.nodes.filter { $0.type == .function }.count
        let types = graph.nodes.filter { $0.type == .class }.count
        let tested = graph.nodes.filter { $0.tags.contains("tested") }.count

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            stat("Files", files)
            stat("Functions", functions)
            stat("Types", types)
            stat("Tested", tested, tint: Theme.tested)
        }
    }

    private func stat(_ label: String, _ value: Int, tint: Color = Theme.accent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
    }

    private func layerRow(index: Int, name: String) -> some View {
        let count = model.arrays.layerIndex.filter { $0 == Int32(index) }.count
        return HStack(spacing: 9) {
            Circle()
                .fill(Palette.color(hue: Palette.layerHue(index), brightness: 0.85))
                .frame(width: 9, height: 9)
            Text(name).font(.callout)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    /// Derives, or shows, what the software is *for*.
    ///
    /// The only view that cannot be computed: no amount of static analysis can
    /// tell you a file implements "Refunds" when the word appears nowhere in
    /// it. So this is explicitly a model call, and says so.
    @ViewBuilder private var domainSection: some View {
        if store.isDerivingDomains {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(store.domainProgress ?? "Working…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        } else if store.hasDomains {
            let domains = model.arrays.indices(ofType: .domain)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(domains, id: \.self) { index in
                    Button {
                        model.select(index)
                        model.focusCamera(on: index)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.arrays.names[index])
                                .font(.callout.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            if !model.arrays.summaries[index].isEmpty {
                                Text(model.arrays.summaries[index])
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(Theme.elevated.opacity(0.6),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("Derive again") { store.deriveDomains() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.accent)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                    What is this software for? Structure cannot answer that — \
                    a model reads the shape of the project and names the \
                    business capabilities it serves.
                    """)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.deriveDomains()
                } label: {
                    Label("Find the domains", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.activeProviderSpec == nil ? Theme.textMuted : Theme.accent)
                .help(store.activeProviderSpec == nil
                      ? "Needs an AI provider — choose one in Settings."
                      : "Ask the model what business capabilities this project serves.")
            }
        }
    }

    /// Play / step / stop for the tour.
    @ViewBuilder private func tourControls(_ tour: [TourStep]) -> some View {
        HStack(spacing: 8) {
            if let current = model.tourStep {
                Button { model.playTour(tour, step: current - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain).help("Previous step (←)")

                Text("\(current + 1) of \(tour.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)

                Button { model.playTour(tour, step: current + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain).help("Next step (→)")

                Spacer()
                Button("Stop") { model.stopTour() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            } else {
                Button {
                    model.playTour(tour, step: 0)
                } label: {
                    Label("Take the tour", systemImage: "play.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Walk the project in order, one part at a time.")
                Spacer()
            }
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 2).padding(.bottom, 2)
    }

    private func tourRow(_ step: TourStep, position: Int, tour: [TourStep]) -> some View {
        let isCurrent = model.tourStep == position
        return Button {
            model.playTour(tour, step: position)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(step.order). \(step.title)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(step.description)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                isCurrent ? Theme.accent.opacity(0.14) : Theme.elevated.opacity(0.6),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle().fill(Theme.accent).frame(width: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var diagnosticsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Copyable, because the useful thing to do with a diagnostics list
            // is paste it into an issue — and "never silently drop errors" is
            // only half kept if they cannot leave the window.
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.diagnostics.plainText(), forType: .string)
                } label: {
                    Label("Copy report", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help("Copy every warning as plain text.")
            }
            Text("\(store.diagnostics.total) note\(store.diagnostics.total == 1 ? "" : "s") "
                 + "while building this graph")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            ForEach(Array(store.diagnostics.issues.prefix(4).enumerated()), id: \.offset) { _, issue in
                Text("• " + issue.message)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pills(_ items: [String], tint: Color) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Node inspector

private struct NodeInspector: View {
    var onOpenFile: (String) -> Void = { _ in }
    @EnvironmentObject private var store: Store
    @ObservedObject var model: GraphViewModel
    let index: Int

    @State private var showExplain = false

    var body: some View {
        let arrays = model.arrays
        let node = store.graph?.nodes[safe: index]

        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.color(for: arrays.types[index]))
                    .frame(width: 3, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(arrays.names[index])
                        .font(.system(size: 15, weight: .semibold))
                        .textSelection(.enabled)
                    Text(arrays.types[index].rawValue.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.color(for: arrays.types[index]))
                }
                Spacer()
                Button {
                    model.select(nil)
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Deselect  (esc)")
            }

            if let node {
                if let path = node.filePath {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textMuted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if node.isEnriched {
                    Text(node.summary)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Honest about what has not happened yet, rather than
                    // inventing prose the app cannot derive.
                    Text("No summary yet — enable AI enrichment to describe this node in plain English.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !node.tags.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(node.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(
                                    (tag == "tested" ? Theme.tested : Theme.accent).opacity(0.14),
                                    in: Capsule()
                                )
                                .foregroundStyle(tag == "tested" ? Theme.tested : Theme.accent)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                actionButton(model.focused == index ? "Unfocus" : "Focus", "circle.dashed") {
                    model.toggleFocus()
                }
                if store.activeProviderSpec != nil {
                    actionButton("Explain", "sparkles") { showExplain = true }
                }
                if let path = store.graph?.nodes[safe: index]?.filePath {
                    actionButton("Read", "doc.text") { onOpenFile(path) }
                    if let root = store.projectRoot {
                        actionButton("Reveal", "folder") {
                            store.revealInFinder(root + "/" + path)
                        }
                    }
                }
            }
            .sheet(isPresented: $showExplain) {
                AskPanel(model: model, searchEngine: nil,
                         explainNodeID: model.arrays.ids[safe: index] ?? "")
                    .environmentObject(store)
            }

            connections
        }
    }

    /// How this node relates to one neighbour.
    private struct Link: Identifiable {
        let id: Int
        let type: EdgeType
        /// True when the edge runs from this node outward.
        let outgoing: Bool
    }

    /// Neighbours with the relationship that joins them.
    ///
    /// "RepositoryCard — function" says almost nothing on its own; "calls →
    /// RepositoryCard" says what you actually wanted to know. One pass over the
    /// edge arrays per selection, which is cheaper than it looks and far
    /// cheaper than the alternative of scanning per row.
    private func links(_ arrays: GraphArrays) -> [Link] {
        var seen: [Int: Link] = [:]
        let me = Int32(index)
        for e in 0..<arrays.edgeCount {
            let a = arrays.edgeSource[e], b = arrays.edgeTarget[e]
            guard a == me || b == me else { continue }
            let other = Int(a == me ? b : a)
            let type = EdgeType.allCases[Int(arrays.edgeType[e])]
            // Keep the strongest relationship when two nodes are joined more
            // than once — the same rule the canvas uses when it collapses
            // parallel edges, so the sidebar and the picture agree.
            if let existing = seen[other],
               existing.type.canonicalWeight >= type.canonicalWeight { continue }
            seen[other] = Link(id: other, type: type, outgoing: a == me)
        }
        // Outgoing first: what this node depends on is usually the question.
        return seen.values.sorted {
            $0.outgoing != $1.outgoing ? $0.outgoing
                : compareUTF16(arrays.names[$0.id], arrays.names[$1.id]) == .orderedAscending
        }
    }

    private var connections: some View {
        let arrays = model.arrays
        let neighbours = Array(links(arrays).prefix(40))

        return VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTIONS  \(arrays.degree[index])")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            if neighbours.isEmpty {
                Text("Nothing links to this node. It may be unused, or reached in a way static analysis cannot see.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(neighbours) { link in
                let neighbour = link.id
                Button {
                    model.select(neighbour)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: link.outgoing ? "arrow.right" : "arrow.left")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accentDim)
                            .frame(width: 10)
                        Text(link.type.rawValue.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                            .frame(minWidth: 52, alignment: .leading)
                        Circle()
                            .fill(Theme.color(for: arrays.types[neighbour]))
                            .frame(width: 6, height: 6)
                        Text(arrays.names[neighbour])
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(link.outgoing
                      ? "This \(arrays.types[index].rawValue) \(link.type.rawValue) \(arrays.names[neighbour])"
                      : "\(arrays.names[neighbour]) \(link.type.rawValue) this \(arrays.types[index].rawValue)")
            }
        }
    }

    private func actionButton(
        _ title: String, _ symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Flow layout

/// Wraps its children onto as many rows as needed.
///
/// Tag and language pills vary in width and there is no telling how many will
/// fit; `HStack` would clip and `LazyVGrid` would force a fixed column count.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
