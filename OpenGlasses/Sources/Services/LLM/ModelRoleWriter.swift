import Foundation

/// Writes a role choice to the setting the role is (Plan KA P1). The one place a picker row or a
/// key card's tap turns into a stored value, so both write the same way. Keys never move out of
/// the Keychain: a choice that makes a model (a live model from a chat key, a model for photos)
/// saves it to the Keychain-backed store the existing editors use.
@MainActor
enum ModelRoleWriter {

    enum Outcome: Equatable {
        case applied
        /// The assistant changed: the caller refreshes the conversation's model.
        case assistantChanged
        /// The live model changed: a live session in progress moves to it.
        case liveModelChanged(id: String)
        /// Nothing was written; the sentence says why.
        case failed(String)
    }

    @discardableResult
    static func apply(_ choice: ModelRoleOption.Choice, role: ModelRole) -> Outcome {
        switch choice {
        case .model(let id):
            guard Config.savedModels.contains(where: { $0.id == id }) else { return missingModel }
            if role == .assistant {
                Config.setActiveModelId(id)
                return .assistantChanged
            }
            Config.setVisionRoleModelId(id)
            return .applied

        case .visionAutomatic:
            Config.setVisionRoleModelId(nil)
            return .applied

        case .newVisionModel(let sourceId, let model):
            var saved = Config.savedModels
            guard let source = saved.first(where: { $0.id == sourceId }) else { return missingModel }
            let config = ModelRoleCatalog.visionModel(from: source, model: model)
            saved.append(config)
            Config.setSavedModels(saved)
            Config.setVisionRoleModelId(config.id)
            return .applied

        case .voice(let preference):
            Config.setTTSEnginePreference(preference)
            return .applied

        case .liveModel(let id):
            guard Config.savedRealtimeModels.contains(where: { $0.id == id }) else { return missingModel }
            Config.setActiveRealtimeModelID(id)
            return .liveModelChanged(id: id)

        case .newLiveModel(let providerID, let model, let sourceId):
            guard let source = Config.savedModels.first(where: { $0.id == sourceId }),
                  let live = ModelRoleCatalog.liveModel(providerID: providerID, model: model, apiKey: source.apiKey)
            else { return missingModel }
            var saved = Config.savedRealtimeModels
            saved.append(live)
            guard Config.setSavedRealtimeModels(saved) else {
                return .failed(String(localized: "Couldn't save the model to Keychain."))
            }
            Config.setActiveRealtimeModelID(live.id)
            return .liveModelChanged(id: live.id)

        case .dictation(let preference):
            Config.chooseRecognizer(preference)
            return .applied
        }
    }

    private static var missingModel: Outcome {
        .failed(String(localized: "That model is no longer saved. Choose another."))
    }
}
