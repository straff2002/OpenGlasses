import Foundation
import LocalAuthentication

/// PURE owner-gate state machine (BM P10). Simple Mode hides the owner Settings surface, but its
/// exit was a plain toggle — anyone holding the phone could flip it and regain Settings, including
/// API-key fields that render decrypted. Exiting Simple Mode (and, optionally, entering Settings)
/// now needs a device-owner grant. This is the PIN half of Plan AJ's deferred "profiles + PIN",
/// extracted; full multi-profile storage stays deferred in AJ. The `LAContext` evaluation lives in
/// `OwnerGateAuth` (the thin edge); every decision is here and unit-tested.
struct OwnerGateMachine: Equatable {
    enum State: Equatable {
        case locked          // gate engaged
        case authenticating  // an auth prompt is in flight
        case unlocked        // owner verified — a single-use grant
    }

    private(set) var state: State = .locked
    /// Whether the most recent attempt failed — drives the "try again" UI.
    private(set) var lastFailed = false

    /// Request an unlock. Returns `true` when the caller should start an auth prompt; `false`
    /// while one is already in flight or the gate already holds a grant (no double-prompting).
    mutating func begin() -> Bool {
        guard state == .locked else { return false }
        state = .authenticating
        lastFailed = false
        return true
    }

    /// Report the auth outcome. Ignored unless an attempt is in flight (a stale callback can't
    /// unlock a gate that was never asked).
    mutating func finish(success: Bool) {
        guard state == .authenticating else { return }
        state = success ? .unlocked : .locked
        lastFailed = !success
    }

    /// Consume the single-use grant (e.g. actually exit Simple Mode). Returns whether a grant was
    /// available; the gate relocks either way, so the next exit needs fresh auth.
    mutating func consume() -> Bool {
        defer { if state == .unlocked { state = .locked } }
        return state == .unlocked
    }

    mutating func relock() {
        state = .locked
        lastFailed = false
    }
}

/// PURE gate-applicability decisions.
enum OwnerGatePolicy {
    /// Only *leaving* Simple Mode needs the gate — entering it (locking the device down before a
    /// hand-off) never does, and re-asserting the current value is a no-op.
    static func requiresGate(togglingSimpleModeTo newValue: Bool, currentlyEnabled: Bool) -> Bool {
        currentlyEnabled && !newValue
    }

    /// With no device auth available (no passcode set) the gate fails OPEN: it can't be stronger
    /// than the device itself, and permanently locking the owner out would be worse.
    static func grantWithoutPrompt(authAvailable: Bool) -> Bool {
        !authAvailable
    }
}

/// Outcome of an owner-authorization request for an operation that must fail **closed**.
///
/// Distinct from `OwnerGatePolicy.grantWithoutPrompt`, which deliberately fails OPEN for the
/// Simple Mode gate (it cannot be stronger than the device, and locking the owner out of their own
/// settings would be worse). Destructive operations on compliance evidence take the opposite
/// default: without a positive decision there is no authorization, so `unavailable` is a refusal.
enum OwnerAuthorization: Equatable {
    case granted
    case denied
    /// No positive decision could be obtained — no device authentication configured, the prompt
    /// could not be presented, or evaluation errored.
    case unavailable

    var isGranted: Bool { self == .granted }

    /// Stable token for audit records; never localized, never free text.
    var auditToken: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unavailable: return "unavailable"
        }
    }
}

/// Thin `LAContext` edge for the owner gate: Face ID / Touch ID with device-passcode fallback
/// (`.deviceOwnerAuthentication` includes both). Same shape as `BiometricLockView`'s HIPAA lock.
enum OwnerGateAuth {
    /// Prompt for device-owner auth and call back on the main queue.
    static func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            let granted = OwnerGatePolicy.grantWithoutPrompt(authAvailable: false)
            DispatchQueue.main.async { completion(granted) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }

    /// Fail-CLOSED owner authorization for destructive operations on compliance evidence.
    ///
    /// Unlike ``authenticate(reason:completion:)`` this never converts "no device authentication
    /// available" into a grant: the caller gets `.unavailable` and must refuse.
    static func authorize(reason: String, completion: @escaping (OwnerAuthorization) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success ? .granted : .denied) }
        }
    }
}
