import XCTest
@testable import OpenGlasses

/// The delete-and-reinstall gate.
///
/// The Keychain outlives an app delete; `UserDefaults` does not. The onboarding gate read that
/// asymmetry as "this user already has keys, so they are set up" and skipped the flow silently —
/// so a returning user landed in a session with no statement of what had survived (their sign-ins)
/// and what had not (every preference they had set). The fix is not to skip differently but to
/// *ask*, and this is the rule that decides when to.
///
/// Pure inputs throughout: no Keychain, no wiped device, no simulator.
final class ReinstallOnboardingGateTests: XCTestCase {

    private func provenance(completed: Bool = false,
                            defaults: Bool = false,
                            credentials: Bool = true) -> Config.LaunchProvenance {
        Config.LaunchProvenance(hasCompletedOnboarding: completed,
                                hasLongLivedDefaults: defaults,
                                hasSavedCredentials: credentials)
    }

    // MARK: - The verdict

    /// The state the feature exists for: credentials on file, nothing behind them.
    func testCredentialsWithNoPreferencesIsAReinstall() {
        XCTAssertTrue(Config.isReinstall(provenance()))
    }

    /// A genuine fresh install has no credentials, and must stay exactly what it was. This is the
    /// assertion that keeps the mainline App Store path byte-identical.
    func testAFreshInstallIsNeverAReinstall() {
        XCTAssertFalse(Config.isReinstall(provenance(credentials: false)))
        XCTAssertFalse(Config.isReinstall(provenance(defaults: true, credentials: false)))
        XCTAssertFalse(Config.isReinstall(provenance(completed: true, credentials: false)))
    }

    /// The corroboration earning its place: without it, "no completion flag" cannot tell a wiped
    /// preference store apart from a user who saved a key and quit the flow half way. Only the
    /// first of those should see the welcome-back page.
    func testASurvivingPreferenceRulesOutAReinstall() {
        XCTAssertFalse(Config.isReinstall(provenance(defaults: true)),
                       "Defaults are intact, so nothing was lost and there is nothing to explain")
    }

    /// Finished onboarding ⇒ not a reinstall, whatever else is true. Belt and braces with the
    /// live-flag re-read in `isReinstallLaunch`.
    func testCompletedOnboardingRulesOutAReinstall() {
        XCTAssertFalse(Config.isReinstall(provenance(completed: true)))
        XCTAssertFalse(Config.isReinstall(provenance(completed: true, defaults: true)))
    }

    // MARK: - The gate it feeds

    /// A reinstall forces the flow on even though the old two-input rule would have waved it past.
    func testReinstallForcesOnboardingOnWhereTheOldRuleSkippedIt() {
        XCTAssertFalse(
            Config.needsOnboarding(hasCompletedOnboarding: false, hasAnyAPIKey: true),
            "Pinning the pre-existing behaviour this replaces: a key alone used to be enough")
        XCTAssertTrue(
            Config.needsOnboarding(hasCompletedOnboarding: false, hasAnyAPIKey: true, isReinstall: true))
    }

    /// Nothing else moves. Every combination without the reinstall flag answers exactly as before.
    func testTheGateIsUnchangedForEveryNonReinstallCase() {
        for completed in [false, true] {
            for hasKey in [false, true] {
                XCTAssertEqual(
                    Config.needsOnboarding(hasCompletedOnboarding: completed, hasAnyAPIKey: hasKey),
                    !completed && !hasKey,
                    "needsOnboarding(completed: \(completed), hasKey: \(hasKey))")
                XCTAssertEqual(
                    Config.needsOnboarding(hasCompletedOnboarding: completed,
                                           hasAnyAPIKey: hasKey,
                                           isReinstall: false),
                    !completed && !hasKey,
                    "an explicit false must read the same as the default")
            }
        }
    }

    /// `isPastOnboarding` is the launch gate for `Wearables.configure()` and the services that
    /// depend on it, so it has to stay the exact negation — including in the new state, where the
    /// glasses stack waits for the user's choice the same way it waits through a first run.
    func testIsPastOnboardingStaysTheNegationInEveryState() {
        for completed in [false, true] {
            for hasKey in [false, true] {
                for reinstall in [false, true] {
                    XCTAssertEqual(
                        Config.isPastOnboarding(hasCompletedOnboarding: completed,
                                                hasAnyAPIKey: hasKey,
                                                isReinstall: reinstall),
                        !Config.needsOnboarding(hasCompletedOnboarding: completed,
                                                hasAnyAPIKey: hasKey,
                                                isReinstall: reinstall))
                }
            }
        }
    }

    /// Both exits from the welcome-back page set the completion flag, and that is what returns the
    /// launch gate to its ordinary answer — the invariant that keeps the SDK-configure path from
    /// being stranded off for a user who chose Restore.
    func testCompletingOnboardingReopensTheLaunchGateForAReinstall() {
        XCTAssertTrue(Config.needsOnboarding(hasCompletedOnboarding: false,
                                             hasAnyAPIKey: true,
                                             isReinstall: true))
        // What the flow writes on the way out, either way it is left.
        XCTAssertTrue(Config.isPastOnboarding(hasCompletedOnboarding: true, hasAnyAPIKey: true),
                      "Once onboarding is complete the reinstall verdict no longer applies")
    }

    /// The corroborating keys are read, never written by the check itself, and there are at least
    /// two of them — one subsystem changing how it stores state must not make every install look
    /// freshly reinstalled.
    func testTheCorroborationRestsOnMoreThanOneKey() {
        XCTAssertGreaterThan(Config.longLivedDefaultsKeys.count, 1)
        XCTAssertEqual(Set(Config.longLivedDefaultsKeys).count, Config.longLivedDefaultsKeys.count)
        XCTAssertFalse(Config.longLivedDefaultsKeys.contains("hasCompletedOnboarding"),
                       "The completion flag is a separate input, not its own corroboration")
    }
}
