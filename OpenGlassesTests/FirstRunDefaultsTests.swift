import XCTest
@testable import OpenGlasses

/// A fresh install has no API key, and that is the mainline first-run path. The resolution below
/// is what keeps the migration from making a blank-key config active — the failure that turned a
/// skipped setup into "API key not configured" on the user's first question.
final class FirstRunDefaultsTests: XCTestCase {

    // MARK: - Fresh install (no legacy key)

    func testFreshInstallStartsOnAppleIntelligenceWhenAvailable() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: false,
                                                appleIntelligenceAvailable: true,
                                                localModelDownloaded: false)
        XCTAssertEqual(resolved, .keyless(.appleOnDevice))
    }

    func testFreshInstallFallsBackToADownloadedLocalModel() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: false,
                                                appleIntelligenceAvailable: false,
                                                localModelDownloaded: true)
        XCTAssertEqual(resolved, .keyless(.local))
    }

    func testAppleIntelligenceWinsOverADownloadedLocalModel() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: false,
                                                appleIntelligenceAvailable: true,
                                                localModelDownloaded: true)
        XCTAssertEqual(resolved, .keyless(.appleOnDevice))
    }

    func testFreshInstallWithNothingKeylessLeavesTheActiveModelUnset() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: false,
                                                appleIntelligenceAvailable: false,
                                                localModelDownloaded: false)
        XCTAssertEqual(resolved, .unconfigured,
                       "No keyless provider runs here — better unset than a blank-key config")
    }

    func testResolvedKeylessProviderNeverRequiresAnAPIKey() {
        for local in [false, true] {
            for apple in [false, true] {
                guard case .keyless(let provider) = FirstRunDefaults.resolve(
                    hasLegacyKey: false, appleIntelligenceAvailable: apple, localModelDownloaded: local
                ) else { continue }
                XCTAssertFalse(provider.requiresAPIKey,
                               "\(provider) was picked as the keyless default but needs a key")
            }
        }
    }

    // MARK: - Existing installs

    func testLegacyKeyKeepsTheMigratedConfigActive() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: true,
                                                appleIntelligenceAvailable: true,
                                                localModelDownloaded: true)
        XCTAssertEqual(resolved, .migratedLegacyKey,
                       "An upgrading user must keep the model they were already using")
    }

    func testLegacyKeyWinsEvenWithNoOnDeviceOption() {
        let resolved = FirstRunDefaults.resolve(hasLegacyKey: true,
                                                appleIntelligenceAvailable: false,
                                                localModelDownloaded: false)
        XCTAssertEqual(resolved, .migratedLegacyKey)
    }

    func testLegacyInstallWithoutAKeyIsTreatedAsFresh() {
        // The old single-provider fields exist but hold empty strings, so the migration produces
        // no config and `hasLegacyKey` is false. Nothing here may claim a legacy key was carried
        // over — that is the branch that used to activate a blank Anthropic config.
        for apple in [false, true] {
            for local in [false, true] {
                let resolved = FirstRunDefaults.resolve(hasLegacyKey: false,
                                                        appleIntelligenceAvailable: apple,
                                                        localModelDownloaded: local)
                XCTAssertNotEqual(resolved, .migratedLegacyKey,
                                  "apple: \(apple), local: \(local)")
            }
        }
    }

    // MARK: - Error copy

    func testMissingCredentialCopyPointsAtBothWaysOut() {
        for provider in LLMProvider.allCases where provider.requiresAPIKey {
            let message = provider.missingCredentialMessage
            XCTAssertTrue(message.contains("Settings"), "\(provider): \(message)")
            XCTAssertTrue(message.contains("on-device"), "\(provider): \(message)")
        }
    }

    func testAnthropicCopyAlsoOffersTheAccountSignIn() {
        let message = LLMProvider.anthropic.missingCredentialMessage
        XCTAssertTrue(message.contains("sign in with Claude"), message)
    }
}
