import SwiftUI

/// Tells you when the graph no longer describes your code.
///
/// A stale graph is worse than no graph: it looks authoritative while being
/// wrong. The banner appears only when there is something to say — a fresh
/// graph shows nothing at all — and it always names an action rather than just
/// reporting a state.
struct StalenessBanner: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var model: GraphViewModel

    @State private var expanded = false

    var body: some View {
        if let freshness = store.freshness, freshness.severity > 0 {
            VStack(alignment: .leading, spacing: 0) {
                header(freshness)
                if expanded, !freshness.changedFiles.isEmpty {
                    fileList(freshness)
                }
            }
            .background(tint(freshness).opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(tint(freshness).opacity(0.35)).frame(height: 1)
            }
        }
    }

    private func header(_ freshness: GitProbe.Freshness) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(freshness))
                .font(.system(size: 12))
                .foregroundStyle(tint(freshness))

            VStack(alignment: .leading, spacing: 1) {
                Text(freshness.headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(freshness.detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !model.diff.isEmpty {
                diffSummary
            }

            if freshness.isActionable {
                Button("Re-analyze") { store.analyze() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(tint(freshness).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(tint(freshness))
            }

            if !freshness.changedFiles.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .help(expanded ? "Hide changed files" : "Show changed files")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// The blast radius, and a toggle to see it on the canvas.
    private var diffSummary: some View {
        Button {
            model.toggleDiff()
        } label: {
            HStack(spacing: 8) {
                dot(Theme.diffChanged, "\(model.diff.changed.count) changed")
                dot(Theme.diffAffected, "\(model.diff.affected.count) affected")
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(
                model.diffMode ? Theme.accent.opacity(0.16) : Theme.elevated.opacity(0.7),
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .help(model.diffMode
              ? "Stop highlighting the change and what depends on it  (d)"
              : "Highlight what changed and what depends on it  (d)")
    }

    private func dot(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    private func fileList(_ freshness: GitProbe.Freshness) -> some View {
        // Capped: a large rebase can change thousands of files and the point of
        // the list is to recognise them, not to enumerate them.
        let files = freshness.changedFiles
        let shown = files.prefix(8)

        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown), id: \.self) { path in
                Button {
                    guard let index = model.arrays.index(of: "file:" + path) else { return }
                    model.select(index)
                    model.focusCamera(on: index)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(Theme.diffChanged)
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            if files.count > shown.count {
                Text("+ \(files.count - shown.count) more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .padding(.leading, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tint(_ freshness: GitProbe.Freshness) -> Color {
        switch freshness {
        case .fresh: return Theme.tested
        // `unknown` is deliberately not treated as fine: an unanswerable
        // question is not a clean bill of health.
        case .unknown: return Theme.textMuted
        case .dirty: return Theme.diffAffected
        case .stale: return Theme.diffChanged
        }
    }

    private func symbol(_ freshness: GitProbe.Freshness) -> String {
        switch freshness {
        case .fresh: return "checkmark.circle"
        case .unknown: return "questionmark.circle"
        case .dirty: return "pencil.circle"
        case .stale: return "exclamationmark.triangle"
        }
    }
}
