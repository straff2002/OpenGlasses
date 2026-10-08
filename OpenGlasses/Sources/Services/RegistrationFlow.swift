import Foundation
import MWDATCore

/// Pure policy for the Meta registration wait — the setup step that most often blocks users
/// (the DAT permission gate is *the* onboarding blocker).
///
/// `Wearables.startRegistration()` returns *before* the user has approved the app inside the Meta
/// AI companion app; `registrationState` only reaches the camera/mic-capable value once they do,
/// and that approval has been observed to take ~25 s. The old 10 s deadline gave up while the user
/// was still tapping through Meta AI, leaving a "connected but nothing works" state — and the
/// status shown was a raw internal state number, not something the user could act on.
enum RegistrationFlow {
    /// How long to keep polling for the Meta AI approval before giving up (still with guidance).
    static let approvalDeadlineSeconds: Int64 = 25
    /// `registrationState` raw value at which camera/mic capabilities become available.
    static let registeredStateRawValue = 3

    static func isRegistered(stateRaw: Int) -> Bool { stateRaw >= registeredStateRawValue }

    /// The bundle ID the published app ships under. A contributor build signs with its own, and
    /// that is what separates "Meta hasn't let this wearer in" from "this build's link-back is
    /// broken" — the two stall registration identically.
    static let publishedBundleID = "com.openglasses.app"

    /// The app's name as Meta AI shows it to the wearer, so the copy names what they approve.
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "this app"
    }

    /// User-facing connection status — tells the user what to *do*, never an internal state number.
    static func status(stateRaw: Int, appName: String = RegistrationFlow.appName) -> String {
        isRegistered(stateRaw: stateRaw)
            ? "Waiting for device…"
            : "Approve \(appName) in the Meta AI app to continue…"
    }

    /// Status once the approval deadline passes without registration. Sized for the status
    /// capsule, and worded for both causes the deadline cannot tell apart: the wearer is still
    /// tapping through Meta AI, or Meta refused them.
    static func approvalTimedOutStatus(appName: String = RegistrationFlow.appName) -> String {
        "Meta AI hasn't approved \(appName) yet — glasses access is invite-only."
    }

    /// What to say *before* the hand-off to Meta AI, where a wearer Meta has not let in sees only
    /// "Internal error — The operation could not be completed" and nothing that names the gate.
    /// Three testers reported exactly that on 2026-10-08. The after-the-fact copy
    /// (`notApprovedMessage`) still applies; this one spares them the round trip.
    static func beforeHandoffMessage(appName: String = RegistrationFlow.appName) -> String {
        "Meta AI opens next to approve \(appName). Meta only completes this for testers invited to "
            + "\(appName)'s beta, or with Developer Mode turned on in Meta AI (Settings › About › tap the "
            + "version number five times). An \"Internal error\" in Meta AI means neither applies yet."
    }

    /// The full explanation for a wearer Meta did not let in.
    ///
    /// Outside Developer Mode, Meta registers a distributed app only for wearers invited to its
    /// release channel. Everyone else is refused inside Meta AI and lands back here with the
    /// registration never completing — which, before this copy, showed them either nothing or
    /// advice about AppLink domains meant for people building the app themselves.
    static func notApprovedMessage(appName: String = RegistrationFlow.appName) -> String {
        "Meta didn't approve \(appName) for your glasses. Glasses access is invite-only for now: "
            + "ask to join the tester group, or turn on Developer Mode in the Meta AI app."
    }

    /// What to tell the wearer when Meta AI's callback reports a failure, or nil when the failure
    /// is not one they can act on (an unregistration callback).
    static func callbackFailureMessage(_ error: WearablesHandleURLError,
                                       appName: String = RegistrationFlow.appName) -> String? {
        switch error {
        case .registrationError:
            return notApprovedMessage(appName: appName)
        case .unregistrationError:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Short, actionable copy for a registration failure.
    ///
    /// Two reasons this exists rather than `error.localizedDescription`. The SDK's own text
    /// describes the SDK's state ("User is already registered"), not what the wearer should do —
    /// and it is rendered in the status capsule, which is sized for "Glasses Idle", so a sentence
    /// is truncated to its first few words. Device-traced 2026-08-23: the truncation cut exactly
    /// the word that would have shown the error was benign.
    ///
    /// `alreadyRegistered` is not in the failure set — `connect()` treats it as success, because
    /// it is the normal state on every connect after the first.
    static func registrationErrorMessage(_ error: RegistrationError) -> String {
        switch error {
        case .alreadyRegistered:
            // Unreachable from `connect()`, which handles this as success. Mapped anyway so a
            // future caller cannot turn it back into a scary string by accident.
            return "Already registered — connecting…"
        case .metaAINotInstalled:
            return "Install the Meta AI app and pair your glasses there first."
        case .networkUnavailable:
            return "No network. Registration needs a connection — reconnect and try again."
        // DAT 1.0 removed `.timeout` (not in its changelog). Our own `approvalDeadlineSeconds`
        // still bounds the wait, and whatever the SDK reports instead lands in `.unknown` or
        // `@unknown default`, whose copy already says what to do.
        case .configurationInvalid:
            return MWDATConfigCheck.message(for: .ok) ?? "This build's Meta SDK configuration is invalid."
        case .unknown:
            return "Registration failed. Restart the glasses and try again."
        @unknown default:
            return "Registration failed. Restart the glasses and try again."
        }
    }

    /// Diagnostic failure message for a connect that gave up — names the stalled layer instead of
    /// a bare "Could not connect to glasses" (issue #246: that string hid a broken registration
    /// link-back for an entire debugging evening). Still actionable, now also diagnosable.
    ///
    /// `configStatus` lets a bad MWDAT config pre-empt the generic advice: a placeholder app ID
    /// stalls registration in exactly the same way a missed link-back does, and telling the user
    /// to re-approve in Meta AI when the *build* is misconfigured sends them down the wrong path
    /// for hours. Defaults to `.ok` so existing callers are unaffected.
    ///
    /// `bundleID` picks the audience for a stalled registration: on the published app the likely
    /// cause is that Meta hasn't let this wearer in, so it gets `notApprovedMessage`; a contributor
    /// build keeps the link-back diagnosis, which is the likely cause there.
    static func connectFailureMessage(stateRaw: Int,
                                      configStatus: MWDATConfigCheck.Status = .ok,
                                      bundleID: String? = Bundle.main.bundleIdentifier,
                                      appName: String = RegistrationFlow.appName) -> String {
        if !isRegistered(stateRaw: stateRaw),
           let configProblem = MWDATConfigCheck.message(for: configStatus) {
            return configProblem
        }
        if isRegistered(stateRaw: stateRaw) {
            return "Glasses registered but no device appeared (state \(stateRaw)). Make sure the glasses are on, nearby, and connected in the Meta AI app, then try again."
        }
        if bundleID == publishedBundleID {
            return notApprovedMessage(appName: appName)
        }
        return "Glasses registration didn't complete (state \(stateRaw)). If you approved \(appName) in the Meta AI app and this persists, the approval link-back may not be reaching this app — on a custom build, verify the AppLink domain and associated-domains entitlement match your bundle ID."
    }
}
