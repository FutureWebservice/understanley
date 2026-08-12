import SwiftUI

/// Reads one file from the project, in a panel over the canvas.
///
/// The graph tells you a function exists and what it connects to; sooner or
/// later you want to read it. Doing that in a separate editor loses the place
/// you were in, so it belongs here.
///
/// **The allowlist is the security boundary.** The app is not sandboxed and can
/// read anything the user can, so a viewer that took an arbitrary path would be
/// a file-disclosure primitive driven by graph content — and graph content can
/// come from a `.ua/knowledge-graph.json` written by someone else. Only paths
/// that appear as a `filePath` on a node in the *current* graph are readable,
/// and each is re-checked for traversal before it is opened.
struct CodeViewer: View {
    let projectRoot: String
    /// Every path the graph knows about. Nothing outside this opens.
    let allowedPaths: Set<String>
    let path: String
    /// Lines to mark, 1-based and inclusive — the selected node's own span.
    var highlight: LineRange?
    var onClose: () -> Void

    @State private var content: Result<[String], LoadError>?
    @State private var fullScreen = false

    enum LoadError: Error {
        case notInGraph
        case unreadable
        case binary
        case tooLarge

        var message: String {
            switch self {
            case .notInGraph:
                return "That file is not part of this graph, so it is not readable here."
            case .unreadable:
                return "This file could not be read. It may have been moved or deleted."
            case .binary:
                return "This looks like a binary file, so there is nothing to show."
            case .tooLarge:
                return "This file is larger than 1 MB — too big to display."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.borderSubtle)
            body(for: content)
        }
        .frame(height: fullScreen ? nil : 340)
        .frame(maxHeight: fullScreen ? .infinity : 340)
        .background(Theme.panel)
        .overlay(alignment: .top) { Divider().overlay(Theme.borderSubtle) }
        .onAppear(perform: load)
        .onChange(of: path) { _ in load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)

            if case .success(let lines) = content {
                Text("\(lines.count) lines")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            Button {
                NSWorkspace.shared.selectFile(
                    projectRoot + "/" + path, inFileViewerRootedAtPath: projectRoot
                )
            } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            .help("Show in Finder")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { fullScreen.toggle() }
            } label: {
                Image(systemName: fullScreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            .help(fullScreen ? "Shrink" : "Fill the window")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.textMuted)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func body(for content: Result<[String], LoadError>?) -> some View {
        switch content {
        case .none:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failure(let error):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.textMuted)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .success(let lines):
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            row(number: index + 1, text: line)
                                .id(index + 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    // Land on the declaration rather than at the top of the
                    // file — the node is the reason the viewer opened.
                    guard let start = highlight?.start else { return }
                    proxy.scrollTo(max(1, start - 3), anchor: .top)
                }
            }
        }
    }

    private func row(number: Int, text: String) -> some View {
        let inRange = highlight.map { number >= $0.start && number <= $0.end } ?? false
        return HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textMuted.opacity(inRange ? 1 : 0.55))
                .frame(width: 40, alignment: .trailing)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(inRange ? Theme.textPrimary : Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .padding(.vertical, 0.5)
        .background(inRange ? Theme.accent.opacity(0.09) : .clear)
    }

    /// Whether a path may be opened at all.
    ///
    /// Both checks matter, and this is the security boundary of the whole
    /// viewer, so it is a plain function that can be tested rather than logic
    /// buried in a SwiftUI body. The allowlist stops a path the graph never
    /// mentioned; `isSafeRelative` stops `../` and absolute paths *inside* one
    /// it did — a `.ua/knowledge-graph.json` can be written by anyone, so a
    /// `filePath` of "../../.ssh/id_rsa" has to be refused even though the
    /// graph does list it.
    static func canOpen(_ path: String, allowedPaths: Set<String>) -> Bool {
        allowedPaths.contains(path) && PosixPath.isSafeRelative(path)
    }

    private func load() {
        content = nil
        guard Self.canOpen(path, allowedPaths: allowedPaths) else {
            content = .failure(.notInGraph)
            return
        }

        let full = projectRoot + "/" + path
        let attributes = try? FileManager.default.attributesOfItem(atPath: full)
        if let size = attributes?[.size] as? Int, size > ScanLimits.maxSourceFileBytes {
            content = .failure(.tooLarge)
            return
        }
        guard let text = FileRead.text(at: full, limit: ScanLimits.maxSourceFileBytes) else {
            content = .failure(.unreadable)
            return
        }
        // A NUL byte means this is not text, whatever the extension claims.
        // Same check the scanner uses, so the viewer and the pipeline agree on
        // what counts as a source file.
        guard !FileRead.looksBinary(Data(text.utf8)) else {
            content = .failure(.binary)
            return
        }
        content = .success(text.components(separatedBy: "\n"))
    }
}
