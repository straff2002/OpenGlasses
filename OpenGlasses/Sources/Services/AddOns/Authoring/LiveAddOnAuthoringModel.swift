import Foundation

enum AddOnAuthoringModelError: Error, Equatable {
    case noModel
    /// The wearer's model runs on the phone; building add-ons needs their cloud model.
    case onDeviceOnly
}

/// The production authoring model: the wearer's own cloud model, one stateless request per call,
/// recorded in Usage as an off-turn call.
///
/// Prefers the isolated one-request route (`DraftCloudTransport`: two strings, no history, no
/// tools, no memory). A provider that route doesn't support (an account sign-in) goes through
/// `fallback`, which the app wires to `LLMService.completeStateless`, the same stateless path the
/// suggested-skills analyser uses. On-device models are refused rather than used: drafting a JSON
/// file from documentation is beyond them, and a background session should not run inference on
/// the phone.
struct LiveAddOnAuthoringModel: AddOnAuthoringModel {

    var fallback: @MainActor (_ system: String, _ user: String) async throws -> String
    static let requestTimeout: TimeInterval = 90

    @MainActor
    func complete(system: String, user: String) async throws -> String {
        guard let config = Config.activeModel else { throw AddOnAuthoringModelError.noModel }
        guard let target = DraftCloudTarget(config: config) else { throw AddOnAuthoringModelError.onDeviceOnly }
        guard target.isSupported else { return try await fallback(system, user) }
        let reply = try await DraftCloudTransport.send(config, instructions: system, prompt: user,
                                                       maxOutputTokens: AddOnAuthoringService.maxOutputTokens,
                                                       timeout: Self.requestTimeout)
        // The isolated route records nothing itself; count it here, as an estimate from length.
        UsageTracker.shared.record(provider: config.llmProvider, model: config.model,
                                   tokensIn: (system.count + user.count) / 4, tokensOut: reply.count / 4)
        return reply
    }
}
