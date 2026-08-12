import Foundation

/// Talks to any hosted or self-hosted model server.
///
/// Two wire formats cover the entire field. That is why the provider list is
/// data rather than a class hierarchy — OpenRouter, Ollama, LM Studio, vLLM,
/// Groq and Together are all the OpenAI format pointed at a different host.
struct HTTPProvider: LLMProvider {
    enum WireFormat: String, Sendable {
        case anthropicMessages
        case openAIChat
    }

    let id: String
    let displayName: String
    let destination: String
    let format: WireFormat
    let baseURL: URL
    let apiKey: String?
    let model: String

    /// Retries on transient failures with exponential backoff. Three attempts
    /// is enough to ride out a brief rate limit without stalling a batch run
    /// behind a server that is genuinely down.
    private let maxAttempts = 3

    init(
        id: String, displayName: String, destination: String,
        format: WireFormat, baseURL: String, apiKey: String?, model: String
    ) throws {
        guard let url = URL(string: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL),
              let scheme = url.scheme?.lowercased(), let host = url.host
        else { throw LLMError.transport("\"\(baseURL)\" is not a valid URL.") }

        // Source code must never leave the machine in cleartext. Plain HTTP is
        // allowed only to loopback, where there is no network to intercept —
        // which is exactly the case that matters, since local model servers
        // rarely bother with TLS.
        if scheme == "http", !Self.isLoopback(host) {
            throw LLMError.insecureEndpoint(host)
        }
        guard scheme == "http" || scheme == "https" else {
            throw LLMError.transport("Unsupported URL scheme \"\(scheme)\".")
        }

        self.id = id
        self.displayName = displayName
        self.destination = destination
        self.format = format
        self.baseURL = url
        self.apiKey = apiKey
        self.model = model
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
            || host.hasSuffix(".localhost")
    }

    // MARK: - Sending

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        var lastError: LLMError = .emptyResponse

        for attempt in 0..<maxAttempts {
            do {
                return try await attemptSend(request)
            } catch let error as LLMError {
                lastError = error
                guard error.isTransient, attempt < maxAttempts - 1 else { throw error }

                // Honour a server-supplied delay when there is one; otherwise
                // back off exponentially from one second.
                var delay = pow(2, Double(attempt))
                if case .rateLimited(let retryAfter) = error, let retryAfter {
                    delay = max(delay, retryAfter)
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }

    private func attemptSend(_ request: LLMRequest) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch format {
        case .anthropicMessages:
            if let apiKey { urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAIChat:
            if let apiKey {
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw LLMError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.transport("The server sent a response this app could not read.")
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw LLMError.unauthorized(displayName)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.serverError(http.statusCode, Self.errorDetail(from: data))
        }

        guard let text = Self.extractText(from: data, format: format), !text.isEmpty else {
            throw LLMError.emptyResponse
        }
        let usage = Self.extractUsage(from: data, format: format)
        return LLMResponse(text: text, inputTokens: usage.input, outputTokens: usage.output)
    }

    private var endpoint: URL {
        switch format {
        case .anthropicMessages:
            return baseURL.appendingPathComponent("v1/messages")
        case .openAIChat:
            // Ollama and most self-hosted servers expose the OpenAI shape under
            // `/v1`; a base URL that already ends in `/v1` should not get a
            // second one.
            return baseURL.path.hasSuffix("/v1")
                ? baseURL.appendingPathComponent("chat/completions")
                : baseURL.appendingPathComponent("v1/chat/completions")
        }
    }

    private func body(for request: LLMRequest) -> [String: Any] {
        switch format {
        case .anthropicMessages:
            return [
                "model": model,
                "max_tokens": request.maxTokens,
                "temperature": request.temperature,
                "system": request.system,
                "messages": [["role": "user", "content": request.user]],
            ]
        case .openAIChat:
            return [
                "model": model,
                "max_tokens": request.maxTokens,
                "temperature": request.temperature,
                "messages": [
                    ["role": "system", "content": request.system],
                    ["role": "user", "content": request.user],
                ],
            ]
        }
    }

    // MARK: - Response parsing

    /// Pulls the assistant text out of either format.
    ///
    /// Parsed defensively with `JSONSerialization` rather than `Codable`: these
    /// are third-party responses, several of them from servers only
    /// approximating the format they claim, and a strict decode would throw
    /// away a usable answer over an unexpected extra field.
    static func extractText(from data: Data, format: WireFormat) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch format {
        case .anthropicMessages:
            guard let content = root["content"] as? [[String: Any]] else { return nil }
            let parts = content.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            return parts.joined()
        case .openAIChat:
            guard let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any]
            else { return nil }
            return message["content"] as? String
        }
    }

    static func extractUsage(from data: Data, format: WireFormat) -> (input: Int?, output: Int?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { return (nil, nil) }
        switch format {
        case .anthropicMessages:
            return (usage["input_tokens"] as? Int, usage["output_tokens"] as? Int)
        case .openAIChat:
            return (usage["prompt_tokens"] as? Int, usage["completion_tokens"] as? Int)
        }
    }

    /// Best-effort human-readable message from an error body.
    static func errorDetail(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScanLimits.clamp(FileRead.decode(data), 200)
        }
        if let error = root["error"] as? [String: Any],
           let message = error["message"] as? String { return ScanLimits.clamp(message, 300) }
        if let message = root["error"] as? String { return ScanLimits.clamp(message, 300) }
        if let message = root["message"] as? String { return ScanLimits.clamp(message, 300) }
        return ScanLimits.clamp(FileRead.decode(data), 200)
    }
}
