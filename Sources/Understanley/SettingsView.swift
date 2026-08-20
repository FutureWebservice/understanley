import AppKit
import SwiftUI

/// Everything the app lets you change, in four tabs.
///
/// It was one scroll of AI options; it is now split because the sheet has more
/// to say than fits, and because the model settings are the only ones that
/// carry a privacy consequence — burying them under a slider for scroll speed
/// would be the wrong emphasis. The disclosure of what leaves the machine stays
/// inline next to the choice, not in a policy and not after the first request.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    /// Which pane is showing. Persisted, so reopening Settings to change the
    /// same thing twice does not start from the top each time.
    @AppStorage("settingsTab") private var tab: Tab = .model
    /// Shared with the onboarding overlay in `ProjectView` — clearing it here
    /// is what makes "Show the tour again" mean anything.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    @AppStorage(CanvasInput.invertedKey) private var invertScroll = false
    @AppStorage(CanvasInput.speedKey) private var scrollSpeed = 1.0

    @State private var selection: String?
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var customURL = UserDefaults.standard.string(forKey: "customEndpointURL") ?? ""
    @State private var customFormat = UserDefaults.standard.string(forKey: "customEndpointFormat")
        ?? "openai"
    @State private var saveNotice: String?
    @State private var connectionTest: ConnectionTest = .idle
    @State private var actionNotice: String?

    enum Tab: String, CaseIterable, Identifiable {
        case model, project, interface, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .model: return "Model"
            case .project: return "Project"
            case .interface: return "Interface"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .model: return "sparkles"
            case .project: return "folder"
            case .interface: return "slider.horizontal.3"
            case .about: return "info.circle"
            }
        }
    }

    /// The result of one real round trip to the configured provider.
    ///
    /// "Ready" in the provider list only means a key exists or a binary is on
    /// PATH. This is the difference between configured and actually working,
    /// which is otherwise discovered halfway through an enrichment run.
    enum ConnectionTest: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    private var spec: ProviderRegistry.Spec? { selection.flatMap(ProviderRegistry.spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.borderSubtle)
            tabBar
            Divider().overlay(Theme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .model: modelPane
                    case .project: projectPane
                    case .interface: interfacePane
                    case .about: aboutPane
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.borderSubtle)
            footer
        }
        .frame(width: 580, height: 640)
        .background(Theme.root)
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            selection = store.providerID
            modelDraft = spec.map { currentModel(for: $0) } ?? ""
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help("Close (⎋)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: candidate.icon).font(.caption)
                        Text(candidate.title).font(.callout)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Theme.elevated.opacity(tab == candidate ? 1 : 0),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .foregroundStyle(tab == candidate ? Theme.accentBright : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var footer: some View {
        HStack {
            if let actionNotice {
                Text(actionNotice)
                    .font(.caption)
                    .foregroundStyle(Theme.tested)
            } else if store.undescribedCount > 0, store.activeProviderSpec != nil {
                Text("\(store.undescribedCount) nodes have no summary yet")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
    }

    // MARK: - Model pane

    private var modelPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            intro
            providerList
            if let spec { configuration(for: spec) }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Optional. The graph is already complete without it.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            Text("""
                Structure — files, functions, imports, call edges, layers, test coverage — is \
                computed on this machine. A model only adds the plain-English summaries and tags.
                """)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The provider catalogue, in a scroll region of its own.
    ///
    /// Bounded rather than free-running: nine providers is taller than the
    /// sheet, and letting the list push the key and model fields off the bottom
    /// means every change of provider costs a scroll to get back to them.
    private var providerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Provider")

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ProviderRegistry.all) { candidate in
                        providerRow(candidate)
                    }
                    noneRow
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 244)
        }
    }

    private var noneRow: some View {
        Button {
            selection = nil
            store.providerID = nil
            connectionTest = .idle
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection == nil ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selection == nil ? Theme.accent : Theme.textMuted)
                Text("None — structure only")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.elevated.opacity(selection == nil ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func providerRow(_ candidate: ProviderRegistry.Spec) -> some View {
        let available = ProviderRegistry.isAvailable(candidate)
        let isSelected = selection == candidate.id

        return Button {
            selection = candidate.id
            store.providerID = candidate.id
            modelDraft = currentModel(for: candidate)
            keyDraft = ""
            connectionTest = .idle
            saveNotice = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(candidate.displayName)
                        if available {
                            Text("ready")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.tested.opacity(0.16), in: Capsule())
                                .foregroundStyle(Theme.tested)
                        }
                    }
                    Text(candidate.costNote)
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.elevated.opacity(isSelected ? 1 : 0.5),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func configuration(for spec: ProviderRegistry.Spec) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // ── What leaves this machine ──
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.caption)
                        .foregroundStyle(Theme.diffAffected)
                    Text("What gets sent")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.diffAffected)
                }
                Text("""
                    To **\(spec.destination)**: file paths, the structure already extracted \
                    (names, signatures, imports, edge counts), and a bounded excerpt of each \
                    file — at most 60 lines or 2 600 characters per node.

                    Never sent: files excluded by your ignore rules, anything outside the \
                    project folder, and your API key beyond the request that needs it.
                    """)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.diffAffected.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.diffAffected.opacity(0.25), lineWidth: 1)
            )

            if spec.id == "custom" { customEndpointFields }
            if let account = spec.keychainAccount { keyField(spec: spec, account: account) }
            if !spec.defaultModel.isEmpty || spec.id == "custom" { modelField(spec: spec) }

            if let saveNotice {
                Text(saveNotice)
                    .font(.caption)
                    .foregroundStyle(Theme.tested)
            }

            connectionCheck(for: spec)
        }
    }

    /// One real request, so "configured" and "working" stop being the same word.
    private func connectionCheck(for spec: ProviderRegistry.Spec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    runConnectionTest(spec)
                } label: {
                    if connectionTest == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(connectionTest == .running)
                .help("Sends one throwaway prompt and reports exactly what came back.")
                Spacer()
            }

            switch connectionTest {
            case .succeeded(let detail):
                testResult(detail, icon: "checkmark.circle", tint: Theme.tested)
            case .failed(let detail):
                testResult(detail, icon: "exclamationmark.triangle", tint: Theme.diffChanged)
            case .idle, .running:
                Text("A throwaway prompt, a few tokens. Nothing from your project is sent.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func testResult(_ detail: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private var customEndpointFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Base URL")
            TextField("https://your-server.example/v1", text: $customURL)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: customURL) { value in
                    UserDefaults.standard.set(value, forKey: "customEndpointURL")
                }
            Text("Must be https://, or http:// on localhost. Plain HTTP to a remote host is "
                 + "refused — a mistyped URL should not ship your source in cleartext.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            label("Message format")
            Picker("", selection: $customFormat) {
                Text("OpenAI chat").tag("openai")
                Text("Anthropic messages").tag("anthropic")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: customFormat) { value in
                UserDefaults.standard.set(value, forKey: "customEndpointFormat")
            }
        }
    }

    private func keyField(spec: ProviderRegistry.Spec, account: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label("API key")
            HStack(spacing: 8) {
                // Write-only by design: the app stores the key in the Keychain
                // and never reads it back to display. A stored key shows as a
                // state, not as characters.
                SecureField(Keychain.has(account) ? "•••••••• stored" : "Paste your key",
                            text: $keyDraft)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))

                Button("Save") {
                    Keychain.write(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                   for: account)
                    keyDraft = ""
                    saveNotice = "Saved to your Keychain."
                    connectionTest = .idle
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                if Keychain.has(account) {
                    Button("Remove") {
                        Keychain.remove(account)
                        saveNotice = "Removed."
                        connectionTest = .idle
                    }
                    .foregroundStyle(Theme.diffChanged)
                }
            }
            Text("Stored in the macOS Keychain, never in a file this app writes.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private func modelField(spec: ProviderRegistry.Spec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Model")
            TextField(spec.defaultModel.isEmpty ? "provider default" : spec.defaultModel,
                      text: $modelDraft)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: modelDraft) { value in
                    UserDefaults.standard.set(value, forKey: "model.\(spec.id)")
                    connectionTest = .idle
                }
            // Free text rather than a fixed list, so a model released next week
            // does not need an app update to be usable.
            Text("Any model id this provider accepts.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
    }

    // MARK: - Project pane

    private var projectPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("ANALYSIS") {
                Toggle(isOn: $store.autoUpdate) {
                    settingLabel(
                        "Keep the graph up to date",
                        """
                        Re-analyze automatically a moment after you save. \
                        Summaries already written are kept.
                        """
                    )
                }
                .toggleStyle(.switch)
                .help("Watches the project folder and rebuilds the graph when it settles.")

                Divider().overlay(Theme.borderSubtle).padding(.vertical, 4)

                Toggle(isOn: $store.autoEnrich) {
                    settingLabel(
                        "Describe new nodes automatically",
                        """
                        After each analysis, run the model over whatever still has no \
                        summary. Off by default: this is the one setting that sends code \
                        without you pressing anything.
                        """
                    )
                }
                .toggleStyle(.switch)
                .disabled(store.activeProviderSpec == nil)
                .help(store.activeProviderSpec == nil
                      ? "Choose a provider in the Model tab first."
                      : "Runs the same pass as the Describe button, unattended.")
            }

            card("STORED WORK") {
                actionRow(
                    "Forget written summaries",
                    """
                    Summaries are written once and then reused forever, including across \
                    re-analysis. Clear them to describe this project again from scratch.
                    """,
                    button: "Clear",
                    enabled: store.projectRoot != nil,
                    help: "Deletes the record of what has already been described."
                ) {
                    store.clearEnrichmentCache()
                    note("Cleared. The next describe pass starts from scratch.")
                }

                Divider().overlay(Theme.borderSubtle).padding(.vertical, 4)

                actionRow(
                    "Show the graph file",
                    """
                    The whole graph is one JSON file inside the project, byte-compatible \
                    with Understand Anything. Nothing about it is hidden from you.
                    """,
                    button: "Reveal",
                    enabled: store.projectRoot != nil,
                    help: "Opens .ua/knowledge-graph.json in Finder."
                ) {
                    guard let root = store.projectRoot else { return }
                    store.revealInFinder(DataDirectory.graphPath(root))
                }

                Divider().overlay(Theme.borderSubtle).padding(.vertical, 4)

                actionRow(
                    "Clear recent projects",
                    "Empties the list on the welcome screen and in File ▸ Open Recent.",
                    button: "Clear",
                    enabled: !store.recentProjects.isEmpty,
                    help: "Forgets every remembered folder. The folders themselves are untouched."
                ) {
                    store.clearRecents()
                    note("Recent projects cleared.")
                }
            }
        }
    }

    // MARK: - Interface pane

    private var interfacePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            card("CANVAS") {
                Toggle(isOn: $invertScroll) {
                    settingLabel(
                        "Invert scroll direction",
                        "Drag the canvas rather than the view. Applies to trackpad and wheel."
                    )
                }
                .toggleStyle(.switch)

                Divider().overlay(Theme.borderSubtle).padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    settingLabel(
                        "Scroll speed",
                        "How far one gesture pans. A big graph wants more; a trackpad wants less."
                    )
                    HStack(spacing: 10) {
                        Slider(value: $scrollSpeed, in: 0.25...3, step: 0.25)
                        Text(String(format: "%.2f×", scrollSpeed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 48, alignment: .trailing)
                        Button("Reset") { scrollSpeed = 1 }
                            .disabled(scrollSpeed == 1)
                    }
                }
            }

            card("GUIDANCE") {
                actionRow(
                    "Show the tour again",
                    """
                    The first-run overlay that points at the search field, the layers and \
                    the two view modes. Shown once, and then never again until you ask.
                    """,
                    button: "Show",
                    enabled: hasSeenOnboarding,
                    help: hasSeenOnboarding
                        ? "Reappears over the graph as soon as you close Settings."
                        : "It has not been dismissed yet."
                ) {
                    hasSeenOnboarding = false
                    note("The tour will reappear when you close Settings.")
                }
            }

            Text("""
                Keyboard shortcuts have their own sheet — press ? on the graph, or pick \
                Keyboard Shortcuts from the toolbar.
                """)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About pane

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "circle.hexagongrid")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Understanley")
                            .font(.system(size: 22, weight: .semibold, design: .serif))
                        Text("Version \(appVersion) · macOS 13+ · zero dependencies")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Text("Point it at any folder. See how the code fits together.")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            card("MADE BY") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shad")
                        .font(.callout.weight(.medium))
                    link("futurewebservice.de", "https://futurewebservice.de")
                    link("github.com/FutureWebservice/understanley",
                         "https://github.com/FutureWebservice/understanley")
                }
            }

            card("BUILT ON") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                        An independent native macOS port of Understand Anything — \
                        © Yuxiang Lin and Infinite Universe, Inc., created by Lum1104 and \
                        maintained under Egonex-AI. MIT-licensed, and not affiliated with \
                        or endorsed by them.
                        """)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    link("github.com/Egonex-AI/Understand-Anything",
                         "https://github.com/Egonex-AI/Understand-Anything")
                }
            }

            card("WHAT IT DOES WITH YOUR CODE") {
                VStack(alignment: .leading, spacing: 5) {
                    aboutLine("The whole analysis runs on this Mac. No account, no server.")
                    aboutLine("Nothing is sent anywhere unless you pick a hosted model above.")
                    aboutLine("API keys live in the macOS Keychain, never in a file this app writes.")
                    aboutLine("The graph is written to .ua/ inside the project, and nowhere else.")
                }
            }

            HStack(spacing: 6) {
                Text("MIT-licensed ·")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                link("Support the project", "https://buymeacoffee.com/futurewebservice")
            }
        }
    }

    private func aboutLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(Theme.textMuted)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link(_ text: String, _ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(text, destination: url)
                    .font(.caption)
                    .foregroundStyle(Theme.accentBright)
            } else {
                Text(text).font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
    }

    private var appVersion: String {
        // Absent when run straight from `swift run` rather than the bundle, so
        // the fallback matches what `--version` prints.
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    // MARK: - Building blocks

    private func card<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionRow(
        _ title: String,
        _ detail: String,
        button: String,
        enabled: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            settingLabel(title, detail)
            Spacer(minLength: 8)
            Button(button, action: action)
                .disabled(!enabled)
                .help(help)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
    }

    private func currentModel(for spec: ProviderRegistry.Spec) -> String {
        UserDefaults.standard.string(forKey: "model.\(spec.id)") ?? spec.defaultModel
    }

    /// A transient line in the footer, so an action that changes nothing
    /// visible still says that it happened.
    private func note(_ message: String) {
        actionNotice = message
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if actionNotice == message { actionNotice = nil }
        }
    }

    // MARK: - Connection test

    private func runConnectionTest(_ spec: ProviderRegistry.Spec) {
        connectionTest = .running
        let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let outcome = await Self.probe(spec: spec, model: model.isEmpty ? nil : model)
            await MainActor.run { connectionTest = outcome }
        }
    }

    /// Off the main actor, and deliberately tiny: the point is to prove the
    /// credentials and the endpoint, not to exercise the enrichment prompt.
    private static func probe(
        spec: ProviderRegistry.Spec, model: String?
    ) async -> ConnectionTest {
        do {
            let provider = try ProviderRegistry.makeProvider(spec, model: model)
            let started = Date()
            let response = try await provider.send(LLMRequest(
                system: "Reply with a single word.",
                user: "Reply with the word: ready",
                maxTokens: 16
            ))
            let elapsed = Date().timeIntervalSince(started)
            let reply = response.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !reply.isEmpty else {
                return .failed("\(provider.displayName) connected but returned nothing.")
            }
            return .succeeded(
                "\(provider.displayName) answered in \(String(format: "%.1f", elapsed))s: "
                + "“\(ScanLimits.clamp(reply, 80))”"
            )
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
