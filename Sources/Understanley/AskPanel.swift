import SwiftUI

/// Ask questions about the codebase, or explain one node.
///
/// Both share a panel because they are the same operation with a different
/// starting point: assemble the relevant subgraph, show what that is, send it.
struct AskPanel: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var model: GraphViewModel
    let searchEngine: SearchEngine?

    @Environment(\.dismiss) private var dismiss

    /// Pre-filled when opened from a node's Explain button.
    var explainNodeID: String?

    @State private var question = ""
    @State private var answer: String?
    @State private var context: AskService.Context?
    @State private var showContext = false
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.borderSubtle)

            if store.activeProviderSpec == nil {
                notConfigured
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if explainNodeID == nil { questionField }
                        if let context { contextSummary(context) }
                        if isWorking { working }
                        if let failure { errorBox(failure) }
                        if let answer { answerBox(answer) }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 620, height: 560)
        .background(Theme.root)
        .foregroundStyle(Theme.textPrimary)
        .onAppear {
            if let explainNodeID { runExplain(explainNodeID) }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(explainNodeID == nil ? "Ask about this codebase" : "Explain")
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                if let explainNodeID,
                   let index = model.arrays.index(of: explainNodeID) {
                    Text(model.arrays.names[index])
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Theme.surface)
    }

    private var notConfigured: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Theme.textMuted)
            Text("This needs an AI provider")
                .font(.headline)
            Text("""
                Everything else in this app works without one. Answering questions in prose is \
                the part that genuinely needs a model.
                """)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var questionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("How does … work?", text: $question, onCommit: runAsk)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(9)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 7))

                Button("Ask", action: runAsk)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }

            // Starters, because a blank box in front of an unfamiliar codebase
            // is a hard place to begin.
            if answer == nil, !isWorking {
                FlowLayout(spacing: 6) {
                    ForEach(Self.starters, id: \.self) { starter in
                        Button {
                            question = starter
                            runAsk()
                        } label: {
                            Text(starter)
                                .font(.caption)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Theme.elevated.opacity(0.7), in: Capsule())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static let starters = [
        "What does this project do?",
        "Where does execution start?",
        "How is data stored?",
        "What is the most complex part?",
    ]

    /// What would be sent, shown before it is.
    private func contextSummary(_ context: AskService.Context) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showContext.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showContext ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text("\(context.nodeIDs.count) nodes · ~\(context.approximateTokens) tokens sent"
                         + " to \(store.activeProviderSpec?.destination ?? "the provider")")
                        .font(.caption)
                }
                .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("See exactly what was sent")

            if showContext {
                ScrollView {
                    Text(context.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 200)
                .background(Theme.elevated.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private var working: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.callout).foregroundStyle(Theme.textSecondary)
        }
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(Theme.diffChanged)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.diffChanged.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func answerBox(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // Every node the answer drew on, clickable — the point of answering
            // from a graph is that you can go and look.
            if let context, !context.nodeIDs.isEmpty {
                Divider().overlay(Theme.borderSubtle)
                Text("MENTIONED")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                FlowLayout(spacing: 5) {
                    ForEach(context.nodeIDs.prefix(14), id: \.self) { id in
                        if let index = model.arrays.index(of: id) {
                            Button {
                                model.select(index)
                                model.focusCamera(on: index)
                                dismiss()
                            } label: {
                                Text(model.arrays.names[index])
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Actions

    private func makeService() -> AskService? {
        guard let root = store.projectRoot, let spec = store.activeProviderSpec,
              let provider = try? ProviderRegistry.makeProvider(spec, model: nil)
        else { return nil }
        return AskService(provider: provider, projectRoot: root)
    }

    private func runExplain(_ nodeID: String) {
        guard let graph = store.graph, let service = makeService() else { return }
        isWorking = true
        failure = nil
        answer = nil

        Task {
            let built = await service.explainContext(
                nodeID: nodeID, graph: graph, arrays: model.arrays
            )
            guard let built else {
                await MainActor.run {
                    isWorking = false
                    failure = "That node is no longer in the graph."
                }
                return
            }
            await MainActor.run { context = built }
            do {
                let result = try await service.explain(context: built)
                await MainActor.run { answer = result; isWorking = false }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }

    private func runAsk() {
        let trimmed = question.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isWorking else { return }
        guard let graph = store.graph, let searchEngine, let service = makeService() else { return }

        isWorking = true
        failure = nil
        answer = nil

        Task {
            let built = await service.askContext(
                question: trimmed, graph: graph, arrays: model.arrays, engine: searchEngine
            )
            await MainActor.run { context = built }
            do {
                let result = try await service.answer(question: trimmed, context: built)
                await MainActor.run { answer = result; isWorking = false }
            } catch {
                await MainActor.run {
                    failure = error.localizedDescription
                    isWorking = false
                }
            }
        }
    }
}
