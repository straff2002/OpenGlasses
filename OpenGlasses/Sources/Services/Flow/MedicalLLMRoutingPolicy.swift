import Foundation

/// The one model-selection rule for Medical Compliance's "Local LLM Only" promise.
///
/// The setting used to be stored and displayed without any inference path reading it. Keeping the
/// decision pure makes the rule testable without loading a model or making a network request; the
/// live `LLMService` supplies the set of models that are actually downloaded on this device.
enum MedicalLLMRoutingPolicy {
    enum Decision: Equatable {
        /// The requested model is already on-device and usable, or the policy is inactive.
        case use(ModelConfig)
        /// A remote model was requested, so use this downloaded on-device model instead.
        case replaceWithLocal(ModelConfig)
        /// The policy is active and no usable on-device model can serve the request.
        case refuse
    }

    static let unavailableMessage =
        "Medical Local LLM Only is on, but no downloaded on-device model is available. "
        + "Download an on-device model in Settings > AI Models, or turn off Local LLM Only "
        + "before using a cloud model."

    static func isEnforced(hipaaMode: Bool, localOnly: Bool) -> Bool {
        hipaaMode && localOnly
    }

    static func decide(
        hipaaMode: Bool,
        localOnly: Bool,
        requested: ModelConfig,
        candidates: [ModelConfig],
        isUsableLocal: (ModelConfig) -> Bool
    ) -> Decision {
        guard isEnforced(hipaaMode: hipaaMode, localOnly: localOnly) else {
            return .use(requested)
        }

        // Apple Foundation Models never leave the device. Their runtime reports its own clear
        // availability error, so no remote replacement is needed or permitted here.
        if requested.llmProvider == .appleOnDevice {
            return .use(requested)
        }
        if requested.llmProvider == .local, isUsableLocal(requested) {
            return .use(requested)
        }

        if let local = candidates.first(where: {
            $0.llmProvider == .local && isUsableLocal($0)
        }) {
            return .replaceWithLocal(local)
        }
        return .refuse
    }
}
