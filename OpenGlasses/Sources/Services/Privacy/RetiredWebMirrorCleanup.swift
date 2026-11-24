import Foundation

/// Removes what the web mirror of the lens left on the phone. The mirror was retired on
/// 2026-11-23. It was a stop-gap from August 2026, for while the native Display path waited on
/// Meta's developer permission, and the native lens works now. It also could never have loaded on
/// the glasses as built: they open only a public HTTPS address with a valid certificate, and the
/// mirror served plain HTTP on the phone's own network (which Release builds already refused).
///
/// A Debug install that ever turned it on still holds the mirror's access token in the Keychain
/// and its preferences. The token opened the mirror's frames to anyone on the same network who
/// had it, and nothing reads it any more, so it is deleted at the first launch of a build without
/// the mirror, not left behind. It runs at launch until it has completed once: a Keychain that
/// cannot be reached before first unlock leaves the done-marker unset, so the next launch tries
/// again. It writes no erasure-ledger entry: nobody asked for this, and there is nothing to replay.
enum RetiredWebMirrorCleanup {

    /// Written once the token is gone.
    static let doneKey = "retiredWebMirrorCleanup.v1"

    /// The Keychain account the mirror's access token was stored under.
    static let tokenKeychainAccount = "hudMirrorBearerToken"

    /// The preferences the mirror kept: its switch, and its suggested follow-ups setting.
    static let retiredPreferenceKeys = [
        "hudMirrorEnabled",
        "followUpsOnMirrorEnabled",
    ]

    enum Outcome: Equatable {
        /// Done on an earlier launch.
        case alreadyDone
        /// The token and the preferences are gone.
        case removed
        /// The token could not be deleted (the Keychain was unreachable). Tried again next launch.
        case incomplete
    }

    /// Delete what is left. Runs at launch beside the other once-behind-a-flag migrations;
    /// `OpenGlassesApp.init()` calls it. One preference read once done. `deleteKeychainItem`
    /// answers true when the item was removed or was never there (`KeychainService.delete`).
    @discardableResult
    static func run(defaults: UserDefaults = .standard,
                    deleteKeychainItem: (String) -> Bool = { KeychainService.delete($0) }) -> Outcome {
        if defaults.bool(forKey: doneKey) { return .alreadyDone }
        for key in retiredPreferenceKeys { defaults.removeObject(forKey: key) }
        guard deleteKeychainItem(tokenKeychainAccount) else { return .incomplete }
        defaults.set(true, forKey: doneKey)
        return .removed
    }
}
