import Foundation

/// Plan HA C5 — the person holding a managed phone is not its administrator.
///
/// Greig, 2026-10-04, on an enrolled phone: "the user can also unlock administrator settings." A
/// profile with the Field Assist edition but neither an admin card nor a passcode fell back to the
/// device owner's Face ID or passcode — which the technician who carries the phone passes. The rule
/// now:
///
/// - **Only an organisation credential opens the administrator view**: a scanned admin card checked
///   against the profile's digest, or the passcode checked against its verifier. Both are already
///   on the phone (Plan CT 3b); nothing new is issued here.
/// - **The device owner's authentication never does** — prompted or not. `OwnerGatePolicy` fails
///   open on a phone with no passcode set (`grantWithoutPrompt`) for the owner's own Simple Mode and
///   Lock Settings; that grant must not reach anything the organisation locked or reserved, and with
///   no `deviceOwner` credential there is no path by which it could.
/// - **No entry point without a credential.** "Administrator Settings" is offered only in the
///   technician's view, and only when the profile issued a card or a passcode.
///
/// What the owner gate still protects on a managed phone is the person's own: Lock Settings, leaving
/// Simple Mode where the organisation has not locked it, and removing the profile (Plan CT PR 4,
/// kept owner-gated by decision). None of those opens a hidden setting — what Settings draws is
/// `SettingsVisibilityPolicy`'s decision whichever gate was passed. An unmanaged phone has no
/// administrator view at all and its owner gate is unchanged.
enum AdministratorAccessPolicy {

    /// Something presented as proof of being the organisation's administrator.
    enum Credential: Equatable, Sendable {
        case card
        case passcode
        /// The phone's own Face ID or passcode, or the owner gate's grant without a prompt.
        case deviceOwner
    }

    /// Whether `credential` may open the administrator view at all under `policy` — before it is
    /// checked. The check itself is `AdminGate.tryCard` / `tryPasscode`.
    static func accepts(_ credential: Credential, policy: AdminPolicy?) -> Bool {
        guard let policy else { return false }
        switch credential {
        case .card: return policy.credentials.cardDigest != nil
        case .passcode: return policy.credentials.passcode != nil
        case .deviceOwner: return false
        }
    }

    /// Whether "Administrator Settings" is offered: the technician's view is in force and the
    /// profile issued a credential the phone can check.
    static func offersUnlock(policy: AdminPolicy?, restricted: Bool) -> Bool {
        guard restricted, let policy else { return false }
        return accepts(.card, policy: policy) || accepts(.passcode, policy: policy)
    }
}
