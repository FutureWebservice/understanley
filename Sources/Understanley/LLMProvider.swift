import Foundation

/// One request to a language model.
struct LLMRequest: Sendable {
    /// Instructions that govern the whole exchange.
    var system: String
    /// The payload being analyzed.
    var user: String
    var maxTokens: Int = 8000
    /// Low, because the task is extraction and description rather than
    /// invention — and because two runs over the same code should agree.
    var temperature: Double = 0.2
}

struct LLMResponse: Sendable {
    var text: String
    var inputTokens: Int?
    var outputTokens: Int?
}

/// Anything that can answer an `LLMRequest`.
protocol LLMProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Where data goes. Shown to the user before the first call.
    var destination: String { get }
    func send(_ request: LLMRequest) async throws -> LLMResponse

    /// How many nodes may share one request.
    ///
    /// A hosted model has a context window measured in hundreds of thousands of
    /// tokens; Apple's on-device model has 4 096 covering prompt *and* reply.
    /// Expressing that as a provider property keeps the enricher free of
    /// per-vendor branching — it just asks how much the provider can hold.
    var batchCapacity: Int { get }
    /// Characters of source to include per node.
    var excerptBudget: Int { get }
    /// How many requests may be in flight at once.
    ///
    /// Hosted providers are happy with several; the on-device model is a single
    /// shared system resource and returns empty content under contention rather
    /// than queueing or erroring, which is indistinguishable from a refusal.
    var maxConcurrency: Int { get }
}

extension LLMProvider {
    var batchCapacity: Int { 14 }
    var excerptBudget: Int { 2600 }
    var maxConcurrency: Int { 4 }
}

enum LLMError: LocalizedError {
    case notConfigured(String)
    case executableMissing(String)
    case unauthorized(String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int, String)
    case transport(String)
    case emptyResponse
    case insecureEndpoint(String)
    /// The on-device model exists but cannot serve a request right now.
    case onDeviceUnavailable(String)
    /// A local agent CLI is installed but has no usable session.
    case cliSignInRequired(tool: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let name):
            return "\(name) is not set up yet. Add its API key in Settings."
        case .executableMissing(let tool):
            return "Could not find `\(tool)` on your PATH. Install it, or pick a different provider."
        case .unauthorized(let name):
            return "\(name) rejected the credentials. The key may be wrong, revoked, or out of quota."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Retrying in \(Int(retryAfter.rounded()))s."
            }
            return "Rate limited. Backing off before retrying."
        case .serverError(let code, let detail):
            return detail.isEmpty ? "The provider returned HTTP \(code)." : "HTTP \(code): \(detail)"
        case .transport(let detail):
            return "Could not reach the provider: \(detail)"
        case .emptyResponse:
            return "The provider returned nothing."
        case .onDeviceUnavailable(let reason):
            return reason
        case .cliSignInRequired(let tool, let detail):
            return """
                \(tool) is not signed in — \(detail)

                Open Terminal and run `\(tool) login`, then try again. \
                Or switch to a provider with an API key in Settings.
                """
        case .insecureEndpoint(let host):
            return """
                Refusing to send source code to \(host) over plain HTTP. \
                Use https://, or a localhost address for a local server.
                """
        }
    }

    /// Whether retrying the same request could plausibly work.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .transport: return true
        case .serverError(let code, _): return code >= 500
        default: return false
        }
    }
}

// MARK: - Registry

/// The provider catalogue, as data.
///
/// Everything is one of two transports, so adding a vendor is appending a
/// struct literal rather than writing a class. OpenRouter, Ollama, LM Studio,
/// vLLM, Groq, Together and any self-hosted server all speak the OpenAI chat
/// format — which is why "custom endpoint" is not a special case here, just the
/// same adapter with a user-supplied URL.
enum ProviderRegistry {
    enum Transport: Sendable {
        /// Spawn a local agent binary; it carries its own authentication.
        case cli(executable: String, arguments: [String])
        case http(format: HTTPProvider.WireFormat, baseURL: String)
        /// Base URL supplied by the user.
        case custom
        /// Apple's on-device model. No key, no endpoint, no network.
        case onDevice
    }

    struct Spec: Sendable, Identifiable {
        var id: String
        var displayName: String
        var transport: Transport
        var defaultModel: String
        /// Nil when the provider needs no key of its own.
        var keychainAccount: String?
        /// Shown in Settings so the trade-off is visible before choosing.
        var costNote: String
        var destination: String
    }

    static let all: [Spec] = [
        Spec(
            id: "claude-cli", displayName: "Claude Code CLI",
            transport: .cli(executable: "claude", arguments: ["-p"]),
            defaultModel: "", keychainAccount: nil,
            costNote: "Uses your existing Claude subscription. No API key needed.",
            destination: "Anthropic, via the claude CLI already signed in on this Mac"
        ),
        Spec(
            id: "codex-cli", displayName: "OpenAI Codex CLI",
            transport: .cli(executable: "codex", arguments: ["exec"]),
            defaultModel: "", keychainAccount: nil,
            costNote: "Uses your existing ChatGPT sign-in. No API key needed.",
            destination: "OpenAI, via the codex CLI already signed in on this Mac"
        ),
        Spec(
            id: "anthropic", displayName: "Anthropic API",
            transport: .http(format: .anthropicMessages, baseURL: "https://api.anthropic.com"),
            defaultModel: "claude-sonnet-5", keychainAccount: "anthropic-api-key",
            costNote: "Billed per token against your Anthropic account.",
            destination: "api.anthropic.com"
        ),
        Spec(
            id: "openai", displayName: "OpenAI API",
            transport: .http(format: .openAIChat, baseURL: "https://api.openai.com"),
            defaultModel: "gpt-4.1-mini", keychainAccount: "openai-api-key",
            costNote: "Billed per token against your OpenAI account.",
            destination: "api.openai.com"
        ),
        Spec(
            id: "openrouter", displayName: "OpenRouter",
            transport: .http(format: .openAIChat, baseURL: "https://openrouter.ai/api"),
            defaultModel: "anthropic/claude-sonnet-4.5", keychainAccount: "openrouter-api-key",
            costNote: "One key, many models. Billed per token by OpenRouter.",
            destination: "openrouter.ai"
        ),
        Spec(
            id: "apple-foundation", displayName: "Apple Intelligence (on-device)",
            transport: .onDevice,
            defaultModel: "", keychainAccount: nil,
            costNote: "Runs on this Mac's Neural Engine. Free, private, works offline.",
            destination: "this Mac — nothing is sent anywhere"
        ),
        Spec(
            id: "ollama", displayName: "Ollama",
            transport: .http(format: .openAIChat, baseURL: "http://127.0.0.1:11434"),
            defaultModel: "qwen2.5-coder:7b", keychainAccount: nil,
            costNote: "Runs entirely on this Mac. Free, and slower than a hosted model.",
            destination: "127.0.0.1:11434 — stays on this machine"
        ),
        Spec(
            id: "custom", displayName: "Custom endpoint",
            transport: .custom,
            defaultModel: "", keychainAccount: "custom-api-key",
            costNote: "Any server speaking the OpenAI or Anthropic message format.",
            destination: "the URL you provide"
        ),
    ]

    static func spec(_ id: String) -> Spec? { all.first { $0.id == id } }

    /// Whether a provider is ready to use right now.
    static func isAvailable(_ spec: Spec) -> Bool {
        switch spec.transport {
        case .cli(let executable, _):
            return Subprocess.which(executable) != nil
        case .http:
            guard let account = spec.keychainAccount else {
                // Keyless and hosted means a local server — reachable only if
                // it is actually running, which `probe` decides.
                return true
            }
            return Keychain.has(account)
        case .custom:
            return !(UserDefaults.standard.string(forKey: "customEndpointURL") ?? "").isEmpty
        case .onDevice:
            return AppleFoundationProvider.isAvailable
        }
    }

    /// Picks a sensible default on first launch by probing in order of least
    /// friction: an already-authenticated CLI beats a key, which beats a local
    /// server the user may not have running.
    static func detectPreferred() -> Spec? {
        // On-device first: it needs no setup, costs nothing, and sends
        // nothing anywhere — if this Mac can run it, it is the best default.
        if let onDevice = spec("apple-foundation"), isAvailable(onDevice) { return onDevice }
        for id in ["claude-cli", "codex-cli", "anthropic", "openai", "openrouter"] {
            if let spec = spec(id), isAvailable(spec) { return spec }
        }
        if let ollama = spec("ollama"), isOllamaRunning() { return ollama }
        return nil
    }

    /// A short, cheap liveness check — a local model server that is installed
    /// but not running should not be offered as ready.
    static func isOllamaRunning() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.6
        request.httpMethod = "GET"

        // A box rather than a captured `var`: the completion handler runs on a
        // URLSession queue, and mutating a captured local from there is a data
        // race the compiler rejects under Swift 6.
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
            var get: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            box.set((response as? HTTPURLResponse)?.statusCode == 200)
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        return box.get
    }

    /// Builds a live provider from a spec plus the user's settings.
    static func makeProvider(_ spec: Spec, model: String?) throws -> any LLMProvider {
        let defaults = UserDefaults.standard
        let resolvedModel = (model?.isEmpty == false ? model : nil)
            ?? defaults.string(forKey: "model.\(spec.id)")
            ?? spec.defaultModel

        switch spec.transport {
        case .cli(let executable, let arguments):
            guard let path = Subprocess.which(executable) else {
                throw LLMError.executableMissing(executable)
            }
            return CLIProvider(
                id: spec.id, displayName: spec.displayName, destination: spec.destination,
                executablePath: path, arguments: arguments, model: resolvedModel
            )

        case .http(let format, let baseURL):
            let key = spec.keychainAccount.flatMap(Keychain.read)
            if spec.keychainAccount != nil, key == nil {
                throw LLMError.notConfigured(spec.displayName)
            }
            return try HTTPProvider(
                id: spec.id, displayName: spec.displayName, destination: spec.destination,
                format: format, baseURL: baseURL, apiKey: key, model: resolvedModel
            )

        case .onDevice:
            if let reason = AppleFoundationProvider.unavailabilityReason {
                throw LLMError.onDeviceUnavailable(reason)
            }
            return AppleFoundationProvider()

        case .custom:
            let baseURL = defaults.string(forKey: "customEndpointURL") ?? ""
            guard !baseURL.isEmpty else { throw LLMError.notConfigured(spec.displayName) }
            let format: HTTPProvider.WireFormat =
                defaults.string(forKey: "customEndpointFormat") == "anthropic"
                ? .anthropicMessages : .openAIChat
            return try HTTPProvider(
                id: spec.id, displayName: spec.displayName,
                destination: URL(string: baseURL)?.host ?? baseURL,
                format: format, baseURL: baseURL,
                apiKey: spec.keychainAccount.flatMap(Keychain.read), model: resolvedModel
            )
        }
    }
}
