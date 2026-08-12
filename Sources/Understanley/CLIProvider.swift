import Foundation

/// Runs a locally-installed coding agent as the model.
///
/// The appeal is that there is no key to manage and no per-token bill: the CLI
/// already carries whatever subscription or sign-in the user has. The cost is
/// that a cold model load is genuinely slow, hence the generous timeout.
struct CLIProvider: LLMProvider {
    /// Substrings that mean "this failed because nobody is signed in".
    /// `authenticate` earns its place separately from `auth` only for clarity —
    /// the real message from an expired Claude session is
    /// "Failed to authenticate: OAuth session expired and could not be refreshed".
    static let authenticationHints = [
        "auth", "login", "log in", "sign in", "signed in", "credential",
        "unauthorized", "session expired", "api key",
    ]

    let id: String
    let displayName: String
    let destination: String
    let executablePath: String
    let arguments: [String]
    let model: String

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        // System and user text are concatenated: these CLIs take a single
        // prompt, with no separate system channel.
        let prompt = request.system + "\n\n---\n\n" + request.user

        var argv = arguments
        if !model.isEmpty {
            argv.append(contentsOf: ["--model", model])
        }

        let result: CommandResult
        do {
            result = try await Task.detached(priority: .userInitiated) { [executablePath, argv] in
                try Subprocess.run(
                    executablePath, argv,
                    // Inherit the environment so the CLI finds its own config
                    // and credentials exactly as it would in a terminal.
                    environment: ProcessInfo.processInfo.environment,
                    stdin: Data(prompt.utf8),
                    timeout: ScanLimits.cliProviderTimeout,
                    maxOutputBytes: 16 * 1024 * 1024
                )
            }.value
        } catch let failure as Subprocess.Failure {
            throw LLMError.transport(failure.localizedDescription)
        }

        guard result.succeeded else {
            // stdout as well as stderr. These CLIs are user-facing programs, not
            // pipeline tools: `claude` prints "Failed to authenticate: OAuth
            // session expired" to *stdout* and exits 1, leaving stderr empty.
            // Reading only stderr turned an actionable message into the useless
            // "claude exited with status 1".
            let tool = PosixPath.basename(executablePath)
            let reported = [result.stderr, result.stdoutText]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let detail = reported ?? "\(tool) exited with status \(result.status)"

            // A CLI that is installed but not signed in fails this way, and the
            // command that fixes it is worth more than the exit code.
            let lowered = detail.lowercased()
            if Self.authenticationHints.contains(where: lowered.contains) {
                throw LLMError.cliSignInRequired(tool: tool, detail: ScanLimits.clamp(detail, 300))
            }
            throw LLMError.serverError(Int(result.status), ScanLimits.clamp(detail, 400))
        }

        let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return LLMResponse(text: text, inputTokens: nil, outputTokens: nil)
    }
}
