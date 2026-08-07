import Foundation

/// Validates the `MWDAT` Info.plist dictionary the Meta DAT SDK reads at configure time.
///
/// Why this exists: the credentials are substituted into the committed Info.plist from build
/// settings (`$(MWDAT_META_APP_ID)` / `$(MWDAT_CLIENT_TOKEN_HASH)`), whose real values live in
/// the gitignored `project.local.yml`. A clone without those settings builds and launches
/// perfectly happily — and then `startRegistration()` never reaches the registered state,
/// because the app identifies itself to Meta with a placeholder ID. The user-visible symptom
/// is not "bad credentials": it is a Connect button that appears to do nothing and a camera
/// permission prompt that never fires (the prompt is gated behind `registrationState >= 3`).
///
/// That failure cost a full debugging session once. It is now named at launch and repeated in
/// the connect-failure message, so the config is always the first suspect it deserves to be.
///
/// Pure — no Bundle/SDK access — so every branch is headless-testable.
enum MWDATConfigCheck {
    enum Status: Equatable {
        /// Credentials look real (no placeholder, no unexpanded build setting).
        case ok
        /// The `MWDAT` dictionary is absent from the Info.plist entirely.
        case missingDictionary
        /// A required key is absent or empty.
        case missingValue(key: String)
        /// The committed placeholder survived — `project.local.yml` never defined the real value.
        case placeholder(key: String)
        /// A literal `$(…)` reached the built plist: the build setting is undefined, so Xcode
        /// left the reference unexpanded. Distinct from `.placeholder` because the fix differs
        /// (a missing *setting*, not a missing *value*).
        case unsubstituted(key: String)

        var isUsable: Bool { self == .ok }
    }

    /// Keys that must carry a real value for registration to succeed.
    static let requiredKeys = ["MetaAppID", "ClientToken"]

    /// Validate an `MWDAT` dictionary as read from the Info.plist.
    static func validate(_ mwdat: [String: Any]?) -> Status {
        guard let mwdat else { return .missingDictionary }
        for key in requiredKeys {
            guard let value = mwdat[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .missingValue(key: key)
            }
            // Order matters: an unexpanded reference is the more specific diagnosis, and the
            // placeholder token can appear inside one (e.g. "AR|$(X)|YOUR_CLIENT_TOKEN_HASH").
            if value.contains("$(") { return .unsubstituted(key: key) }
            if value.contains("YOUR_") { return .placeholder(key: key) }
        }
        return .ok
    }

    /// One-line diagnosis for the launch log and the connect-failure path. Names the fix, not
    /// just the fault — and never prints the credential values themselves.
    static func message(for status: Status) -> String? {
        switch status {
        case .ok:
            return nil
        case .missingDictionary:
            return "Glasses config missing: the Info.plist has no MWDAT dictionary, so the Meta SDK can't identify this app. Registration will never complete."
        case .missingValue(let key):
            return "Glasses config incomplete: MWDAT.\(key) is empty. Registration will never complete."
        case .placeholder(let key):
            return "Glasses config is still the committed placeholder (MWDAT.\(key)). Set MWDAT_META_APP_ID and MWDAT_CLIENT_TOKEN_HASH in the gitignored project.local.yml, then re-run Scripts/generate-xcodeproj.sh. Until then registration stalls before the camera permission prompt can appear."
        case .unsubstituted(let key):
            return "Glasses config unsubstituted: MWDAT.\(key) still contains a literal $(…) build-setting reference, so the setting is undefined in this build. Define MWDAT_META_APP_ID and MWDAT_CLIENT_TOKEN_HASH (project.local.yml) and regenerate the project."
        }
    }
}
