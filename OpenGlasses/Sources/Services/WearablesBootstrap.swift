import Foundation
import MWDATCore

/// Single owner of `Wearables.configure()`, configuring **on demand at the point of use**.
///
/// # Why this exists
///
/// MWDAT answers *any* `Wearables.shared` access with `fatalError` when the SDK was never
/// configured — not a throw, so there is nothing to catch:
///
/// ```
/// MWDATCore/Wearables.swift: Fatal error: Call `configure()` before attempting to access Wearables!
/// ```
///
/// Configuration used to be gated on `Config.hasCompletedOnboarding`, which was standing in for
/// "the SDK is configured". Those two facts can diverge, and did: onboarding is only *shown* when
/// `Config.needsOnboarding`, which additionally requires that no API key is saved. Save a key
/// before finishing onboarding and neither holds — onboarding stops appearing, nothing calls
/// `configure()`, there is no in-app route back to onboarding, and the first `Wearables.shared`
/// touch kills the process. Tapping Connect was fatal.
///
/// So don't derive it from a flag. Configure where the SDK is actually used, once, and report
/// whether it worked. Callers that can't proceed without it degrade to "Meta SDK not registered",
/// which is the honest state, rather than trapping.
///
/// The deferral this replaces existed for a real reason — `configure()` triggers the Bluetooth
/// permission prompt, and we don't want that on first launch before the user has reached for the
/// glasses. On-demand configuration preserves that: the prompt still waits until something actually
/// needs the SDK. It just no longer depends on two flags staying in sync.
@MainActor
enum WearablesBootstrap {

    /// Whether `configure()` has succeeded. `false` also covers "not attempted yet" — callers
    /// should go through ``ensureConfigured()`` rather than reading this to decide.
    private(set) static var isConfigured = false

    /// Whether we have already tried. `configure()` runs at most once per process: a second call
    /// is not a supported recovery path, and retrying on every access would re-prompt.
    private static var didAttempt = false

    /// Why configuration failed, for diagnostics surfaces. `nil` before the first attempt and
    /// after a successful one.
    private(set) static var failureReason: String?

    /// Configure the SDK if it hasn't been configured yet, and report whether it is usable.
    ///
    /// Safe to call from anywhere, repeatedly, including paths that may run before onboarding.
    /// Call this before touching `Wearables.shared` — the return value is the permission to.
    @discardableResult
    static func ensureConfigured() -> Bool {
        if didAttempt { return isConfigured }
        didAttempt = true
        // Before configure(), so the SDK's analytics uploader can never win a race with it.
        // The Info.plist opt-out is what should stop those uploads; this is the backstop that
        // makes it true in code we own. See MetaTelemetryBlock.
        MetaTelemetryBlock.install()
        do {
            try Wearables.configure()
            isConfigured = true
            failureReason = nil
            NSLog("[Wearables] SDK configured")
        } catch {
            isConfigured = false
            failureReason = error.localizedDescription
            NSLog("[Wearables] configure() failed — glasses features unavailable: %@",
                  error.localizedDescription)
        }
        return isConfigured
    }

    /// One-line state for diagnostics/debug surfaces.
    static var statusDescription: String {
        if isConfigured { return "configured" }
        if let failureReason { return "unavailable — \(failureReason)" }
        return "not configured"
    }

    /// Thrown by callers that cannot degrade any further than "no glasses".
    struct Unavailable: LocalizedError {
        let reason: String?
        var errorDescription: String? {
            "Meta SDK not registered\(reason.map { " — \($0)" } ?? "")"
        }
    }

    /// Configure, or throw a readable error. For throwing entry points that have no fallback.
    static func requireConfigured() throws {
        guard ensureConfigured() else { throw Unavailable(reason: failureReason) }
    }

    #if DEBUG
    /// Reset for tests. Never call from app code — `configure()` is not re-entrant in production.
    static func resetForTesting() {
        isConfigured = false
        didAttempt = false
        failureReason = nil
    }
    #endif
}
