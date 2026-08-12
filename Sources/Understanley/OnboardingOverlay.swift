import SwiftUI

/// Shown once, over the canvas, the first time a graph appears.
///
/// A canvas app is opaque on first contact: there is a picture, and no evident
/// way in. Every one of these is also a permanent affordance elsewhere — a
/// visible button, a menu item, the `?` sheet — so this is a first push rather
/// than the only route to anything.
///
/// Dismissal is remembered, so it never appears twice. It is deliberately *not*
/// a multi-step wizard: five modal steps before someone has looked at their own
/// project is worse than none.
struct OnboardingOverlay: View {
    var onDismiss: () -> Void

    private struct Hint: Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let detail: String
    }

    private static let hints: [Hint] = [
        Hint(key: "⌘F", title: "Find anything",
             detail: "Search by name, tag or summary. ↑↓ steps through the matches and flies to each."),
        Hint(key: "U", title: "Two views",
             detail: "Blueprint is the precise one. Universe shows the same nodes as constellations."),
        Hint(key: "T", title: "Take the tour",
             detail: "Walks the project in order, starting from where it introduces itself."),
        Hint(key: "L", title: "Hide the noise",
             detail: "Filter whole categories — functions, docs, config — when the graph is busy."),
        Hint(key: "O", title: "Read the code",
             detail: "Opens the selected file in place, at the line the node is declared on."),
    ]

    var body: some View {
        ZStack {
            // Dimmed, and the whole backdrop dismisses. Nobody should have to
            // hunt for the way out of a hint panel.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your project, as a graph")
                        .font(.system(size: 17, weight: .semibold, design: .serif))
                    Text("""
                        Every file, function and class is a node; every import, call and \
                        containment is an edge. Nothing was sent anywhere to build this.
                        """)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 16)

                Divider().overlay(Theme.borderSubtle)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.hints) { hint in
                        HStack(alignment: .top, spacing: 12) {
                            Text(hint.key)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 30, alignment: .center)
                                .padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 5))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hint.title)
                                    .font(.callout.weight(.medium))
                                Text(hint.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(22)

                Divider().overlay(Theme.borderSubtle)

                HStack {
                    Text("Press ? at any time for the full list.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button("Start exploring", action: onDismiss)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
            .frame(width: 460)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(Theme.borderSubtle, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}
