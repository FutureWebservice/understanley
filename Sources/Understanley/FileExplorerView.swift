import SwiftUI

/// The project as a path tree, mirroring upstream's "Files" sidebar tab.
///
/// The graph answers "what depends on what"; a lot of the time the question is
/// simply "where does this live". A tree answers that in one glance and gives a
/// way into the graph for anyone who thinks in folders rather than in edges.
///
/// Built as a flat row list with an explicit expansion set rather than nested
/// `DisclosureGroup`s. Nesting them pins the main thread on a large project —
/// SwiftUI evaluates the whole subtree even while it is collapsed — and this
/// tree can hold thousands of paths.
struct FileExplorerView: View {
    @ObservedObject var model: GraphViewModel
    let onOpen: (String) -> Void

    @State private var expanded: Set<String> = []
    @State private var filter = ""

    /// One line in the flattened tree.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let depth: Int
        let isDirectory: Bool
        /// Graph node for a file, when there is one.
        let nodeIndex: Int?
        let childCount: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            filterField
            Divider().overlay(Theme.borderSubtle)
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in
                            rowView(row)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .onAppear(perform: expandFirstLevel)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption2)
                .foregroundStyle(Theme.textMuted)
            TextField("Filter paths", text: $filter)
                .textFieldStyle(.plain)
                .font(.caption)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(filter.isEmpty ? "No files in this graph." : "No path matches “\(filter)”.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if !filter.isEmpty {
                Button("Clear filter") { filter = "" }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        Button {
            if row.isDirectory {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } else if let index = row.nodeIndex {
                model.select(index)
                model.focusCamera(on: index)
                onOpen(row.id)
            }
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(row.depth) * 12)
                if row.isDirectory {
                    Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 9)
                } else {
                    Circle()
                        .fill(row.nodeIndex.map { Theme.color(for: model.arrays.types[$0]) }
                              ?? Theme.textMuted)
                        .frame(width: 5, height: 5)
                        .frame(width: 9)
                }
                Text(row.name)
                    .font(.caption)
                    .foregroundStyle(row.isDirectory ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if row.isDirectory {
                    Text("\(row.childCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                row.nodeIndex != nil && row.nodeIndex == model.selected
                    ? Theme.accent.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tree

    /// Visible rows for the current expansion and filter.
    ///
    /// Recomputed rather than cached: the whole tree is a few thousand strings
    /// at most, and a stale cache after a selection or a filter keystroke is a
    /// far worse bug than the work this costs.
    private var rows: [Row] {
        let arrays = model.arrays
        var indexByPath: [String: Int] = [:]
        for index in 0..<arrays.count where arrays.flags[index].contains(.fileLevel) {
            // The file path is the node id minus its type prefix.
            let id = arrays.ids[index]
            guard let colon = id.firstIndex(of: ":") else { continue }
            let path = String(id[id.index(after: colon)...])
            if indexByPath[path] == nil { indexByPath[path] = index }
        }

        let needle = filter.lowercased()
        let paths = needle.isEmpty
            ? Array(indexByPath.keys)
            : indexByPath.keys.filter { $0.lowercased().contains(needle) }
        guard !paths.isEmpty else { return [] }

        // Directory -> number of descendants, for the count badge.
        var childCounts: [String: Int] = [:]
        for path in paths {
            var parts = path.split(separator: "/").map(String.init)
            parts.removeLast()
            var prefix = ""
            for part in parts {
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                childCounts[prefix, default: 0] += 1
            }
        }

        // While filtering, every ancestor of a match is forced open — otherwise
        // the matches are hidden inside collapsed folders and the filter looks
        // broken.
        let openDirectories: Set<String> = needle.isEmpty ? expanded : Set(childCounts.keys)

        var out: [Row] = []
        var emitted: Set<String> = []

        for path in paths.sorted(by: { compareUTF16($0, $1) == .orderedAscending }) {
            let parts = path.split(separator: "/").map(String.init)
            var prefix = ""
            var visible = true

            for (depth, part) in parts.enumerated() {
                let isLast = depth == parts.count - 1
                prefix = prefix.isEmpty ? part : prefix + "/" + part
                guard visible else { break }

                if !emitted.contains(prefix) {
                    emitted.insert(prefix)
                    out.append(Row(
                        id: prefix, name: part, depth: depth,
                        isDirectory: !isLast,
                        nodeIndex: isLast ? indexByPath[path] : nil,
                        childCount: childCounts[prefix] ?? 0
                    ))
                }
                if !isLast, !openDirectories.contains(prefix) { visible = false }
            }
        }
        return out
    }

    private func expandFirstLevel() {
        guard expanded.isEmpty else { return }
        expanded = Set(rows.filter { $0.depth == 0 && $0.isDirectory }.map(\.id))
    }
}
