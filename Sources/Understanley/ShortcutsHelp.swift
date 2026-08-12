import SwiftUI

/// The keyboard map.
///
/// Every shortcut is also a visible button with a tooltip, so this is a
/// reference rather than the only route to anything. It exists because a
/// canvas app rewards learning its keys, and nobody discovers them by guessing.
struct ShortcutsHelp: View {
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id = UUID()
        let key: String
        let action: String
    }

    private static let groups: [(String, [Entry])] = [
        ("View", [
            Entry(key: "u", action: "Switch between Blueprint and Universe"),
            Entry(key: "0", action: "Fit the whole graph on screen"),
            Entry(key: "f", action: "Focus the selection and its neighbours"),
            Entry(key: "d", action: "Highlight what changed, and what depends on it"),
            Entry(key: "i", action: "Show or hide the inspector"),
            Entry(key: "l", action: "Filter by category — hide functions, docs, config…"),
            Entry(key: "x", action: "Choose which files are excluded from analysis"),
        ]),
        ("Navigate", [
            Entry(key: "drag", action: "Pan"),
            Entry(key: "scroll", action: "Pan · ⌘scroll or pinch to zoom"),
            Entry(key: "click", action: "Select a node"),
            Entry(key: "⌘F", action: "Search — ↑↓ to step through results, ↩ to keep one"),
            Entry(key: "t", action: "Take the guided tour — ←→ to step through it"),
            Entry(key: "p", action: "Path finder: press on one node, then on another"),
            Entry(key: "esc", action: "Back out: viewer, path, tour, search, focus, selection"),
        ]),
        ("Do", [
            Entry(key: "a", action: "Ask a question about this codebase"),
            Entry(key: "e", action: "Explain the selection — or export, with nothing selected"),
            Entry(key: "o", action: "Read the selected file"),
            Entry(key: "⌘R", action: "Re-analyze the project"),
            Entry(key: "⌘O", action: "Open another project"),
            Entry(key: ",", action: "AI provider settings"),
            Entry(key: "?", action: "This list"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(Theme.surface)

            Divider().overlay(Theme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.0.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textMuted)
                            ForEach(group.1) { entry in
                                HStack(spacing: 12) {
                                    Text(entry.key)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .frame(width: 52)
                                        .padding(.vertical, 3)
                                        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Theme.borderSubtle, lineWidth: 1)
                                        )
                                    Text(entry.action)
                                        .font(.callout)
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 460, height: 500)
        .background(Theme.root)
        .foregroundStyle(Theme.textPrimary)
    }
}
