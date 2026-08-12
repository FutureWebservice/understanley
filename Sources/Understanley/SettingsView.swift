import SwiftUI

/// AI provider configuration.
///
/// The app works fully without any of this, so the sheet opens on that fact
/// rather than hiding it. The disclosure of what leaves the machine is shown
/// inline next to the choice — not buried in a privacy policy, and not after
/// the first request has already gone out.
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    @State private var keyDraft = ""
    @State private var modelDraft = ""
    @State private var customURL = UserDefaults.standard.string(forKey: "customEndpointURL") ?? ""
    @State private var customFormat = UserDefaults.standard.string(forKey: "customEndpointFormat")
        ?? "openai"
    @State private var saveNotice: String?

    private var spec: ProviderRegistry.Spec? { selection.flatMap(ProviderRegistry.spec) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    intro
                    providerList
                    if let spec { configuration(for: spec) }
                    projectSection
                }
                .padding(20)
            }

            Divider().overlay(Theme.borderSubtle)
            footer
        }
        .frame(width: 560, height: 620)
        .background(Theme.root)
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            selection = store.providerID
            modelDraft = spec.map { currentModel(for: $0) } ?? ""
        }
    }

    // MARK: Sections

    /// Settings about the project rather than the model.
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROJECT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)

            Toggle(isOn: $store.autoUpdate) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the graph up to date")
                        .font(.callout)
                    Text("""
                        Re-analyze automatically a moment after you save. \
                        Summaries already written are kept.
                        """)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .help("Watches the project folder and rebuilds the graph when it settles.")

            Divider().overlay(Theme.borderSubtle).padding(.vertical, 4)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forget written summaries")
                        .font(.callout)
                    Text("""
                        Summaries are written once and then reused forever, \
                        including across re-analysis. Clear them to describe \
                        this project again from scratch.
                        """)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Clear") { store.clearEnrichmentCache() }
                    .disabled(store.projectRoot == nil)
                    .help("Deletes the record of what has already been described.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack {
            Text("AI enrichment")
                .font(.system(size: 17, weight: .semibold, design: .serif))
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.surface)
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

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 6) {
            label("Provider")

            ForEach(ProviderRegistry.all) { candidate in
                providerRow(candidate)
            }

            Button {
                selection = nil
                store.providerID = nil
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
    }

    private func providerRow(_ candidate: ProviderRegistry.Spec) -> some View {
        let available = ProviderRegistry.isAvailable(candidate)
        let isSelected = selection == candidate.id

        return Button {
            selection = candidate.id
            store.providerID = candidate.id
            modelDraft = currentModel(for: candidate)
            keyDraft = ""
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
        }
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
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                if Keychain.has(account) {
                    Button("Remove") {
                        Keychain.remove(account)
                        saveNotice = "Removed."
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
                }
            // Free text rather than a fixed list, so a model released next week
            // does not need an app update to be usable.
            Text("Any model id this provider accepts.")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
        }
    }

    private var footer: some View {
        HStack {
            if store.undescribedCount > 0, store.activeProviderSpec != nil {
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

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textMuted)
    }

    private func currentModel(for spec: ProviderRegistry.Spec) -> String {
        UserDefaults.standard.string(forKey: "model.\(spec.id)") ?? spec.defaultModel
    }
}
