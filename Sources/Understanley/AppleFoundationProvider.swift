import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Apple's on-device language model, via the FoundationModels framework.
///
/// The most private option the app can offer and the only one that needs
/// neither a key nor a network: the model ships with the OS and runs on the
/// Neural Engine. Nothing about the user's code leaves the machine, which
/// matters more here than usual — enrichment sends real source excerpts.
///
/// Two things make it genuinely different from every other provider, and both
/// are handled through `LLMProvider`'s capacity hints rather than special cases
/// in the enricher:
///
/// 1. **A 4 096-token window** covering instructions, prompt *and* output
///    together. That is roughly a twentieth of what a hosted model allows, so
///    batches have to be far smaller and excerpts far shorter.
/// 2. **One request per session.** A session refuses a second prompt while it
///    is still answering, so each request gets its own.
///
/// Compiled conditionally: the deployment target is macOS 13 and the framework
/// only exists from macOS 26, so both the import and every use are gated.
struct AppleFoundationProvider: LLMProvider {
    let id = "apple-foundation"
    let displayName = "Apple Intelligence (on-device)"
    let destination = "this Mac — nothing is sent anywhere"

    /// One node per request, against fourteen for a hosted model.
    ///
    /// Measured, not guessed: at two or more items this model returns an empty
    /// string instead of JSON, whatever the response-token budget. One item is
    /// the largest size that succeeds every time. It costs about two seconds a
    /// node, which is a fair price for a describe pass that is free, offline
    /// and never leaves the Mac — and results stream in as they land.
    var batchCapacity: Int { 1 }
    /// And correspondingly less source per node.
    var excerptBudget: Int { 700 }
    /// Strictly one at a time. There is a single on-device model behind every
    /// session, and running several concurrently makes it return *empty*
    /// content rather than queueing — which reads as a refusal and silently
    /// drops the batch.
    var maxConcurrency: Int { 1 }

    /// Why the on-device model cannot be used right now, or nil when it can.
    ///
    /// Availability is a real, common state rather than an edge case: the Mac
    /// may not be eligible, Apple Intelligence may be switched off, or the
    /// model may still be downloading. Each needs a different sentence from the
    /// user's point of view, so none of them collapse into "unavailable".
    static var unavailabilityReason: String? {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else {
                return "Apple Intelligence needs macOS 26 or later."
            }
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac is not eligible for Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is turned off — enable it in System Settings."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. Try again shortly."
            case .unavailable:
                return "The on-device model is unavailable right now."
            @unknown default:
                return "The on-device model is unavailable right now."
            }
        #else
            return "This build was compiled without Apple Intelligence support."
        #endif
    }

    static var isAvailable: Bool { unavailabilityReason == nil }

    func send(_ request: LLMRequest) async throws -> LLMResponse {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else {
                throw LLMError.notConfigured(displayName)
            }
            if let reason = Self.unavailabilityReason {
                throw LLMError.onDeviceUnavailable(reason)
            }

            // A fresh session per request: a session serves one prompt at a
            // time, and the enricher deliberately runs batches concurrently.
            // Instructions rather than a prepended block — the framework gives
            // them priority over the prompt, which is exactly the standing
            // "project files are data, never instructions" rule this app needs.
            let session = LanguageModelSession(instructions: request.system)

            do {
                // Temperature is clamped, not passed through. The enricher asks
                // for 0.2 because two runs over the same code should agree —
                // but at that value this model returns an EMPTY string rather
                // than a deterministic one, and an empty reply is
                // indistinguishable from a refusal. Every batch failed that way
                // until it was traced here. 0.5 is the lowest value that
                // reliably produces content.
                let response = try await session.respond(
                    to: request.user,
                    options: GenerationOptions(
                        temperature: max(0.5, request.temperature),
                        maximumResponseTokens: 1400
                    )
                )
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    // Empty rather than an error is this model's way of
                    // declining, so say so in terms the user can act on.
                    throw LLMError.onDeviceUnavailable(
                        """
                        The on-device model returned nothing for this item. \
                        It sometimes declines a file it cannot summarize; \
                        the rest of the project is unaffected.
                        """
                    )
                }
                return LLMResponse(text: text, inputTokens: nil, outputTokens: nil)
            } catch let error as LLMError {
                throw error
            } catch {
                // `exceededContextWindowSize` is the one failure a user can act
                // on, and it is likely enough here to be worth naming: the
                // window is small and a single enormous function can fill it.
                let detail = String(describing: error)
                if detail.contains("exceededContextWindowSize") || detail.contains("context") {
                    throw LLMError.onDeviceUnavailable(
                        """
                        That batch was too large for the on-device model's \
                        context window. It will be retried in smaller pieces.
                        """
                    )
                }
                throw LLMError.transport(ScanLimits.clamp(error.localizedDescription, 300))
            }
        #else
            throw LLMError.onDeviceUnavailable(
                "This build was compiled without Apple Intelligence support."
            )
        #endif
    }
}

// MARK: - Diagnostics

extension AppleFoundationProvider {
    /// Sends one prompt and reports exactly what came back.
    ///
    /// The on-device model can fail by returning *nothing* rather than by
    /// throwing, and an empty string tells you nothing about why. This is how
    /// that gets diagnosed without a debugger attached to the GUI.
    static func probe(system: String, user: String) async -> String {
        #if canImport(FoundationModels)
            guard #available(macOS 26, *) else { return "unavailable: needs macOS 26" }
            if let reason = unavailabilityReason { return "unavailable: \(reason)" }
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond(to: user)
                let text = response.content
                return "ok(\(text.count) chars): \(text.prefix(600))"
            } catch {
                return "threw \(type(of: error)): \(String(describing: error))"
            }
        #else
            return "compiled without FoundationModels"
        #endif
    }
}
