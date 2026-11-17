import Foundation
import os

/// Vision honesty for the ChatGPT (Codex/Responses) subscription provider.
///
/// `LLMProvider.chatgpt` authenticates against the ChatGPT Codex backend and discovers the
/// account's model catalog dynamically. Each catalog row says which inputs that model accepts
/// (`input_modalities`), so whether a photo may go is a per-model reading of the signed-in
/// account's own catalog (`ChatGPTImageInput`), not a guess from the model's name.
///
/// When the catalog doesn't say a model takes images (it lists the model as text-only, or there is
/// no catalog for this account yet), a photo is refused out loud before a byte is sent. Sending it
/// anyway, behind a system prompt that insists "You CAN see it — never deny vision", produces
/// either an odd denial or (worse) a hallucinated description of a scene the model never saw.
///
/// This mirrors the on-device Vision honesty gate in `LLMService.sendMessage`. Pure and state-free
/// so the routing decision is unit-testable without touching the network, `.shared` services, or
/// Config.
enum ChatGPTVisionGate {
    enum Decision: Equatable {
        /// Proceed normally — there's no image this turn, the provider isn't ChatGPT, or the
        /// account's catalog says this model takes images.
        case sendWithImage
        /// Refuse the image turn: speak `message` instead of building a vision-insisting system
        /// prompt or sending any image bytes to the backend.
        case declineVision(message: String)
    }

    /// Spoken/shown when a photo turn reaches a ChatGPT model that doesn't take images. Matches the
    /// app's existing not-configured/can't-see copy: plain, spoken-friendly, names the real
    /// alternatives rather than just failing.
    static let declineMessage =
        "This ChatGPT model can't see photos. Choose one that can in Settings, add an OpenAI API key, switch to Gemini, or use the on-device model instead."

    /// Decide whether a turn's image should reach the ChatGPT provider. Only ever declines for
    /// `.chatgpt` with an image attached and a model the catalog doesn't list as taking images;
    /// every other provider, and every ChatGPT turn without an image, is a no-op.
    static func decide(provider: LLMProvider, hasImage: Bool, acceptsImages: Bool) -> Decision {
        guard provider == .chatgpt, hasImage, !acceptsImages else { return .sendWithImage }
        return .declineVision(message: declineMessage)
    }
}

/// Which ChatGPT subscription models take images, read from the signed-in account's catalog.
///
/// `ChatGPTContextCatalog` (main actor) records it whenever a catalog is stored, and at sign-in or
/// launch from the stored copy; `ModelConfig.visionEnabled`, the fallback chain and the send-time
/// gate read it from any thread. Unknown — signed out, no catalog yet, or one stored before image
/// input was kept — means no model takes images.
enum ChatGPTImageInput {
    private static let models = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)

    /// Replace what is known. Nil forgets it: no ChatGPT model is treated as taking images.
    static func record(_ ids: [String]?) {
        let value = ids.map(Set.init)
        models.withLock { $0 = value }
    }

    /// True only when the current account's catalog lists `model` as taking images.
    static func accepts(_ model: String) -> Bool {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.withLock { $0?.contains(model) ?? false }
    }

    /// The keys a catalog row may name its input modalities under (upstream snake_case, the
    /// App Server camelCase projection, and an older alias).
    static let modalityKeys = ["input_modalities", "inputModalities", "supported_input_modalities"]

    /// Whether one catalog row accepts image input. A row that names its modalities takes images
    /// only when `image` is among them. A row that names none takes images: the upstream client
    /// treats a missing field as text and image (the backward-compatible default for payloads that
    /// predate modality metadata), and the backend is built to that contract.
    static func rowAcceptsImages(_ row: [String: Any]) -> Bool {
        guard let key = modalityKeys.first(where: { row[$0] != nil }) else { return true }
        guard let modalities = row[key] as? [String] else { return false }
        return modalities.contains { $0.lowercased() == "image" }
    }
}

/// One-time reset of a ChatGPT model's saved "Vision off".
///
/// Until vision followed the catalog, the model editor could only save `supportsVision: false` for
/// a ChatGPT model (its inferred default), so that stored `false` records the old rule, not a
/// choice. Once, it goes back to "follow the catalog" (nil); a `false` saved after this has run is
/// the wearer's and stays.
enum ChatGPTVisionOverrideReset {
    static let doneKey = "chatGPTVisionOverrideReset.v1"

    /// Clears the stored `false` on every ChatGPT model the first time it runs. Returns whether it
    /// changed anything, so the caller saves.
    static func apply(to models: inout [ModelConfig], defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: doneKey) else { return false }
        defaults.set(true, forKey: doneKey)
        var changed = false
        for index in models.indices
        where models[index].llmProvider == .chatgpt && models[index].supportsVision == false {
            models[index].supportsVision = nil
            changed = true
        }
        return changed
    }

    /// What the model editor saves for its Vision toggle. A ChatGPT model's vision follows its
    /// account's catalog, so only a real choice is stored: "off" for a model the catalog says can
    /// see. Anything else is nil (follow the catalog) — the toggle is set before sign-in loads the
    /// catalog, and saving that early `false` would keep a seeing model blind for good. Every other
    /// provider stores the toggle as it is.
    static func storedOverride(provider: LLMProvider, model: String, chosen: Bool) -> Bool? {
        guard provider == .chatgpt else { return chosen }
        return !chosen && ChatGPTImageInput.accepts(model) ? false : nil
    }
}
