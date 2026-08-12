import SwiftUI

/// Edits `.understandignore`, with a preview of what the change would do.
///
/// The file has always been honoured; there was simply no way to write one
/// without leaving the app. `IgnoreFilter.starterFile` already generated a
/// sensible draft from `.gitignore` plus per-language test conventions — it had
/// no caller.
///
/// Two rules this keeps from upstream:
///
/// - **Everything generated is commented out.** The starter is a menu, not a
///   policy. Silently excluding a third of someone's project because their
///   `.gitignore` mentioned it would be a graph that is wrong in a way they
///   cannot see.
/// - **Nothing is overwritten unsighted.** If a file already exists it is
///   loaded for editing, and the generated draft is offered as an explicit,
///   labelled replacement rather than applied on open.
struct IgnoreEditorView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    /// What was on disk when the sheet opened, so "unsaved changes" is real.
    @State private var original = ""
    @State private var showingGeneratedDraft = false
    @State private var saveError: String?

    private var path: String {
        (store.projectRoot ?? "") + "/.understandignore"
    }

    private var isDirty: Bool { text != original }

    /// How many files the current text would exclude, over and above the
    /// built-in rules. Recomputed live — this is the whole reason the editor
    /// is worth having rather than a text editor.
    private var effect: (excluded: Int, total: Int) {
        guard let graph = store.graph else { return (0, 0) }
        let paths = graph.nodes.compactMap(\.filePath)
        let unique = Array(Set(paths))
        let filter = IgnoreFilter(patterns: IgnoreFilter.lines(of: text))
        return (unique.filter { filter.isIgnored($0) }.count, unique.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.borderSubtle)
            editor
            Divider().overlay(Theme.borderSubtle)
            footer
        }
        .frame(width: 640, height: 620)
        .background(Theme.root)
        .foregroundStyle(Theme.textPrimary)
        .onAppear(perform: load)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Excluded files")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            }
            Text(".understandignore — same syntax as .gitignore. Built-in exclusions "
                 + "(node_modules, dist, lockfiles…) always apply and need no entry.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if showingGeneratedDraft {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").font(.caption)
                    Text("This is a generated draft — nothing is excluded until you "
                         + "uncomment it and save.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(Theme.accent.opacity(0.08))
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Theme.surface)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(Theme.diffChanged)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                // The live count is the point of the sheet: a rule that
                // excludes nothing is almost always a typo, and one that
                // excludes everything is a mistake you want to see *before*
                // waiting for a re-analysis to tell you.
                let effect = effect
                Label(
                    effect.total == 0
                        ? "Analyze the project to preview the effect"
                        : "\(effect.excluded) of \(effect.total) analyzed files would be excluded",
                    systemImage: effect.excluded > 0 ? "eye.slash" : "eye"
                )
                .font(.caption)
                .foregroundStyle(effect.excluded > effect.total / 2 && effect.total > 0
                                 ? Theme.diffAffected : Theme.textSecondary)

                Spacer()

                Button("Generate draft") { generate() }
                    .help("Build a starting point from .gitignore and this project's test conventions.")

                Button("Save") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .padding(18)
    }

    // MARK: - Actions

    private func load() {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        text = existing
        original = existing
        showingGeneratedDraft = false
        if existing.isEmpty { generate() }
    }

    private func generate() {
        let gitignore = try? String(
            contentsOfFile: (store.projectRoot ?? "") + "/.gitignore", encoding: .utf8
        )
        text = IgnoreGenerator.starterFile(
            gitignore: gitignore,
            languages: store.graph?.project.languages ?? []
        )
        showingGeneratedDraft = true
    }

    private func save() {
        guard let root = store.projectRoot else { return }
        do {
            try text.write(toFile: root + "/.understandignore",
                           atomically: true, encoding: .utf8)
            original = text
            showingGeneratedDraft = false
            saveError = nil
            // Re-analyze: the whole reason to edit this file is to change what
            // the graph contains, so making the user then find Reanalyze would
            // be leaving the job half done.
            store.analyze()
            dismiss()
        } catch {
            saveError = "Could not write .understandignore: \(error.localizedDescription)"
        }
    }
}
