import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Which model configuration a first launch should make active.
///
/// A fresh install has no API key, and that is the mainline path off the App Store — so the
/// initial active model must be one that answers questions without a key rather than one that
/// throws "API key not configured" on the user's first question.
enum FirstRunDefault: Equatable {
    /// A legacy single-provider key was found and migrated — that config stays active, unchanged.
    case migratedLegacyKey
    /// No key anywhere: start on a provider that needs none.
    case keyless(LLMProvider)
    /// Nothing keyless is usable on this device either. Leave the active model unset; the send
    /// path's error copy points at Settings.
    case unconfigured
}

/// Pure resolution of the first-launch default, plus the device probes that feed it.
///
/// The resolution itself takes plain values so it is unit-testable without a Keychain, a
/// filesystem, or Apple Intelligence.
enum FirstRunDefaults {

    /// Decide what a first launch should activate.
    ///
    /// - Parameters:
    ///   - hasLegacyKey: a pre-multi-model install had a real (non-empty) provider key.
    ///   - appleIntelligenceAvailable: the on-device system model is present and enabled.
    ///   - localModelDownloaded: at least one on-device model has been downloaded.
    static func resolve(hasLegacyKey: Bool,
                        appleIntelligenceAvailable: Bool,
                        localModelDownloaded: Bool) -> FirstRunDefault {
        // An upgrading user keeps exactly the model they were already using.
        if hasLegacyKey { return .migratedLegacyKey }
        if appleIntelligenceAvailable { return .keyless(.appleOnDevice) }
        if localModelDownloaded { return .keyless(.local) }
        return .unconfigured
    }

    /// Whether the Apple on-device system model can serve a request right now. False on every
    /// OS/device that can't run it, so it is safe to call before offering it as the default.
    ///
    /// Probed once per process: the migration path is re-entered on every read of the saved model
    /// list while that list is empty, and the answer can't change under a running app anyway.
    static let appleIntelligenceAvailable: Bool = {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }()
}
