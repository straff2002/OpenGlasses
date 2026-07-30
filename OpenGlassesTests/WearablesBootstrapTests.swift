import XCTest
@testable import OpenGlasses

/// Plan CD P1 — the flag desync that caused the launch/Connect crash, and the fail-soft contract
/// that replaced it.
///
/// These deliberately never call `WearablesBootstrap.ensureConfigured()`. `Wearables.configure()`
/// runs at most once per process and cannot be undone, and MWDAT is hostile in a unit-test host, so
/// invoking it here would leak irreversible state into every other test in the bundle. What is
/// testable without the SDK is the onboarding predicate and the state machine around configure() —
/// which is exactly where the defect was.
@MainActor
final class WearablesBootstrapTests: XCTestCase {

    // MARK: - The desync (the actual bug)

    /// The crash in one assertion. `configure()` was gated on `hasCompletedOnboarding`, but the
    /// onboarding *screen* is gated on `needsOnboarding`, which also requires that no API key is
    /// saved. Save a key before finishing onboarding and the two disagree: the screen stops
    /// appearing so the flag is never set, nothing ever calls `configure()`, and there is no in-app
    /// route back — leaving every `Wearables.shared` access fatal.
    func testKeySavedWithoutCompletingOnboardingIsTheDesyncCase() {
        let hasCompletedOnboarding = false
        let hasAnyAPIKey = true

        XCTAssertFalse(
            Config.needsOnboarding(hasCompletedOnboarding: hasCompletedOnboarding,
                                   hasAnyAPIKey: hasAnyAPIKey),
            "a saved key suppresses the onboarding screen"
        )
        XCTAssertTrue(
            Config.isPastOnboarding(hasCompletedOnboarding: hasCompletedOnboarding,
                                    hasAnyAPIKey: hasAnyAPIKey),
            "…so this user must count as past onboarding — gating services on the raw flag left the glasses stack permanently off"
        )
        XCTAssertNotEqual(
            hasCompletedOnboarding,
            Config.isPastOnboarding(hasCompletedOnboarding: hasCompletedOnboarding,
                                    hasAnyAPIKey: hasAnyAPIKey),
            "the two predicates must be shown to diverge here, or this test is not covering the bug"
        )
    }

    /// Full truth table, so the fix can't be narrowed to the one reported case.
    func testOnboardingTruthTable() {
        let cases: [(completed: Bool, hasKey: Bool, needs: Bool)] = [
            (false, false, true),   // fresh install — show onboarding
            (false, true, false),   // the desync case — screen suppressed, so treat as past it
            (true, false, false),   // completed, keys added later
            (true, true, false),    // ordinary configured user
        ]
        for c in cases {
            XCTAssertEqual(
                Config.needsOnboarding(hasCompletedOnboarding: c.completed, hasAnyAPIKey: c.hasKey),
                c.needs,
                "needsOnboarding(completed: \(c.completed), hasKey: \(c.hasKey))"
            )
            XCTAssertEqual(
                Config.isPastOnboarding(hasCompletedOnboarding: c.completed, hasAnyAPIKey: c.hasKey),
                !c.needs,
                "isPastOnboarding must be the exact negation"
            )
        }
    }

    func testLivePredicatesStayInSyncWithTheirPureForms() {
        XCTAssertEqual(Config.isPastOnboarding, !Config.needsOnboarding)
    }

    // MARK: - Fail-soft contract

    /// MWDAT answers an unconfigured `Wearables.shared` with `fatalError`, so the whole point is
    /// that callers get a catchable error instead. Pin the type's existence and its message.
    func testUnavailableErrorReadsAsAnHonestState() {
        let withReason = WearablesBootstrap.Unavailable(reason: "no MWDAT configuration")
        XCTAssertEqual(withReason.errorDescription,
                       "Meta SDK not registered — no MWDAT configuration")
        let bare = WearablesBootstrap.Unavailable(reason: nil)
        XCTAssertEqual(bare.errorDescription, "Meta SDK not registered")
    }

    /// "Not attempted" and "attempted and failed" need opposite fixes, so they must not report the
    /// same thing. Conflating a bad configuration with an absent one is a real time sink.
    func testStatusDescriptionDistinguishesNotAttemptedFromFailed() {
        WearablesBootstrap.resetForTesting()
        XCTAssertEqual(WearablesBootstrap.statusDescription, "not configured")
        XCTAssertFalse(WearablesBootstrap.isConfigured)
        XCTAssertNil(WearablesBootstrap.failureReason)
    }

    func testResetForTestingClearsEveryField() {
        WearablesBootstrap.resetForTesting()
        XCTAssertFalse(WearablesBootstrap.isConfigured)
        XCTAssertNil(WearablesBootstrap.failureReason)
        XCTAssertEqual(WearablesBootstrap.statusDescription, "not configured")
    }
}
