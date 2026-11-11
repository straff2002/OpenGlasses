import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Plan KT §4.2 — the models a card's draft can be written by, as they are on this phone now, and
/// one isolated call to whichever `DraftRoutePolicy` chose. Apple's model gets a session built for
/// the call with no tools and no transcript; the local model gets the two strings and an empty
/// history; the cloud model gets one `DraftCloudTransport` request. Nothing here reads or writes the
/// conversation, and nothing is logged.
@MainActor
final class LivePreparedCardDraftEngine: DraftModelEngine {
    private let localModel: () -> LocalLLMService?

    init(localModel: @escaping () -> LocalLLMService?) {
        self.localModel = localModel
    }

    static var appleOnDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The wearer's active model, when it is a cloud one.
    static var activeCloudConfig: ModelConfig? {
        guard let config = Config.activeModel, DraftCloudTarget(config: config) != nil else { return nil }
        return config
    }

    func routeInputs(carriesCaptionText: Bool) -> DraftRouteInputs {
        DraftRouteInputs(
            appleOnDeviceAvailable: Self.appleOnDeviceAvailable,
            localModelLoaded: localModel()?.isModelLoaded ?? false,
            isForeground: UIApplication.shared.applicationState == .active,
            choice: Config.preparedCardDraftWriter,
            cloud: Self.activeCloudConfig.flatMap(DraftCloudTarget.init(config:)),
            cloudConsent: Config.preparedCardDraftCloudConsent,
            hipaaMode: Config.hipaaMode,
            medicalLocalOnly: MedicalLLMRoutingPolicy.isEnforced(hipaaMode: Config.hipaaMode,
                                                                 localOnly: Config.hipaaLocalOnly),
            carriesCaptionText: carriesCaptionText)
    }

    func run(_ request: DraftModelRequest) async throws -> String {
        switch request.route {
        case .appleOnDevice:
            return try await runApple(request)
        case .localModel:
            guard let local = localModel(), local.isModelLoaded,
                  UIApplication.shared.applicationState == .active else {
                throw DraftCallFailure.modelFailed
            }
            return try await local.generate(userMessage: request.prompt, systemPrompt: request.instructions,
                                            history: [])
        case .cloud(let target):
            // The saved model is read again: the target the route was chosen for must still be
            // the active one, at the same address, and still agreed to.
            guard let config = Self.activeCloudConfig, DraftCloudTarget(config: config) == target,
                  Config.preparedCardDraftCloudConsent == target.consentKey, !Config.hipaaMode else {
                throw DraftCallFailure.noRoute(.cloudNotConsented)
            }
            return try await DraftCloudTransport.send(config, instructions: request.instructions,
                                                      prompt: request.prompt,
                                                      maxOutputTokens: request.maxOutputTokens)
        }
    }

    private func runApple(_ request: DraftModelRequest) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession(instructions: request.instructions)
            let options = GenerationOptions(maximumResponseTokens: request.maxOutputTokens)
            return try await session.respond(to: request.prompt, options: options).content
        }
        #endif
        throw DraftCallFailure.modelFailed
    }
}
