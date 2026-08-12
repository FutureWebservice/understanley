import SwiftUI

/// Root view: welcome screen until a project is open, then the graph.
struct ContentView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        ZStack {
            Theme.root.ignoresSafeArea()

            if store.projectRoot == nil {
                WelcomeView()
            } else if store.isAnalyzing {
                AnalyzingView()
            } else if let error = store.lastError {
                AnalysisErrorView(message: error)
            } else if store.hasGraph {
                ProjectView()
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .preferredColorScheme(.dark)
        .foregroundStyle(Theme.textPrimary)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Image(systemName: "circle.hexagongrid")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Theme.accent)

                Text("Understanley")
                    .font(.system(size: 40, weight: .semibold, design: .serif))

                Text("Point it at any folder. See how the code fits together.")
                    .font(.title3)
                    .foregroundStyle(Theme.textSecondary)
            }

            Button {
                store.chooseProject()
            } label: {
                Text("Choose a folder…")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Theme.borderMedium, lineWidth: 1)
            )
            .foregroundStyle(Theme.accentBright)
            .padding(.top, 34)
            .help("Analyze a project folder. Nothing leaves your machine.")

            Text("No account, no server, no AI required.")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 12)

            if !store.recentProjects.isEmpty {
                recents.padding(.top, 44)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 4)

            ForEach(store.recentProjects, id: \.self) { path in
                Button {
                    store.open(path)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PosixPath.basename(path))
                                .foregroundStyle(Theme.textPrimary)
                            Text(abbreviate(path))
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: 420, alignment: .leading)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Reveal in Finder") { store.revealInFinder(path) }
                    Button("Remove from Recents") { store.forgetRecent(path) }
                }
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Analyzing

struct AnalyzingView: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(store.progressMessage.isEmpty ? "Analyzing…" : store.progressMessage)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
            Button("Cancel") { store.cancelAnalysis() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textMuted)
                .padding(.top, 6)
        }
    }
}

// MARK: - Error

struct AnalysisErrorView: View {
    @EnvironmentObject private var store: Store
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 38))
                .foregroundStyle(Theme.diffAffected)
            Text("Could not analyze this folder")
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                Button("Try again") { store.analyze() }
                Button("Choose another folder") { store.chooseProject() }
            }
            .padding(.top, 8)
        }
        .padding(40)
    }
}
