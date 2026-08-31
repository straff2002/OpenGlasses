import XCTest
@testable import OpenGlasses

/// Plan BG P5 — pins the key, default, and round-trip for each `Config` toggle migrated to
/// `@UserDefaultsBacked`. A wrong key or default in the wrapper is a *silent* behaviour change,
/// so these guard the migration: each assertion ties the property to its exact UserDefaults key.
final class ConfigDefaultsTests: XCTestCase {

    private let keys = [
        "silentMode", "glassesOnlyAudio", "audioOnlyMode", "memoryNudgesEnabled",
        "siriAskOpensApp", "mcpServerEnabled", "accessibilityModeEnabled",
        // Cohort 2
        "usePhoneMicForTranslation", "glassesDisplayEnabled", "intentClassifierEnabled",
        "llmComplexityClassifierEnabled", "agentOnboardingComplete", "contextualEmbeddingEnabled",
        "frameDedupEnabled", "visualStateMemoryEnabled",
        // Cohort 3
        "hasCompletedOnboarding", "autoModelRoutingEnabled", "openClawEnabled", "privacyFilterEnabled",
        "shareHealthDataWithAI", "agentModelDownloaded", "localAgentEnabled", "visualStateInjectThumbnails",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    /// Absent key → `false`, matching the legacy `UserDefaults.bool(forKey:)` getter.
    func testDefaultsAreFalse() {
        XCTAssertFalse(Config.silentMode)
        XCTAssertFalse(Config.glassesOnlyAudio)
        XCTAssertFalse(Config.audioOnlyMode)
        XCTAssertFalse(Config.memoryNudgesEnabled)
        XCTAssertFalse(Config.siriAskOpensApp)
        XCTAssertFalse(Config.mcpServerEnabled)
        XCTAssertFalse(Config.accessibilityModeEnabled)
        XCTAssertFalse(Config.usePhoneMicForTranslation)
        XCTAssertFalse(Config.glassesDisplayEnabled)
        XCTAssertFalse(Config.intentClassifierEnabled)
        XCTAssertFalse(Config.llmComplexityClassifierEnabled)
        XCTAssertFalse(Config.agentOnboardingComplete)
        XCTAssertFalse(Config.contextualEmbeddingEnabled)
        XCTAssertFalse(Config.frameDedupEnabled)
        XCTAssertFalse(Config.visualStateMemoryEnabled)
        XCTAssertFalse(Config.hasCompletedOnboarding)
        XCTAssertFalse(Config.autoModelRoutingEnabled)
        XCTAssertFalse(Config.openClawEnabled)
        XCTAssertFalse(Config.privacyFilterEnabled)
        XCTAssertFalse(Config.shareHealthDataWithAI)
        XCTAssertFalse(Config.agentModelDownloaded)
        XCTAssertFalse(Config.localAgentEnabled)
        XCTAssertFalse(Config.visualStateInjectThumbnails)
    }

    /// Each `setX` façade writes the property, and it round-trips through the exact legacy key.
    func testSettersRoundTripThroughTheCorrectKey() {
        assertRoundTrip("silentMode", set: Config.setSilentMode, get: { Config.silentMode })
        assertRoundTrip("glassesOnlyAudio", set: Config.setGlassesOnlyAudio, get: { Config.glassesOnlyAudio })
        assertRoundTrip("audioOnlyMode", set: Config.setAudioOnlyMode, get: { Config.audioOnlyMode })
        assertRoundTrip("memoryNudgesEnabled", set: Config.setMemoryNudgesEnabled, get: { Config.memoryNudgesEnabled })
        assertRoundTrip("siriAskOpensApp", set: Config.setSiriAskOpensApp, get: { Config.siriAskOpensApp })
        assertRoundTrip("mcpServerEnabled", set: Config.setMCPServerEnabled, get: { Config.mcpServerEnabled })
        assertRoundTrip("accessibilityModeEnabled", set: Config.setAccessibilityModeEnabled, get: { Config.accessibilityModeEnabled })
        assertRoundTrip("usePhoneMicForTranslation", set: Config.setUsePhoneMicForTranslation, get: { Config.usePhoneMicForTranslation })
        assertRoundTrip("glassesDisplayEnabled", set: Config.setGlassesDisplayEnabled, get: { Config.glassesDisplayEnabled })
        assertRoundTrip("intentClassifierEnabled", set: Config.setIntentClassifierEnabled, get: { Config.intentClassifierEnabled })
        assertRoundTrip("llmComplexityClassifierEnabled", set: Config.setLLMComplexityClassifierEnabled, get: { Config.llmComplexityClassifierEnabled })
        assertRoundTrip("agentOnboardingComplete", set: Config.setAgentOnboardingComplete, get: { Config.agentOnboardingComplete })
        assertRoundTrip("contextualEmbeddingEnabled", set: Config.setContextualEmbeddingEnabled, get: { Config.contextualEmbeddingEnabled })
        assertRoundTrip("frameDedupEnabled", set: Config.setFrameDedupEnabled, get: { Config.frameDedupEnabled })
        assertRoundTrip("visualStateMemoryEnabled", set: Config.setVisualStateMemoryEnabled, get: { Config.visualStateMemoryEnabled })
        assertRoundTrip("hasCompletedOnboarding", set: Config.setHasCompletedOnboarding, get: { Config.hasCompletedOnboarding })
        assertRoundTrip("autoModelRoutingEnabled", set: Config.setAutoModelRoutingEnabled, get: { Config.autoModelRoutingEnabled })
        assertRoundTrip("openClawEnabled", set: Config.setOpenClawEnabled, get: { Config.openClawEnabled })
        assertRoundTrip("privacyFilterEnabled", set: Config.setPrivacyFilterEnabled, get: { Config.privacyFilterEnabled })
        assertRoundTrip("shareHealthDataWithAI", set: Config.setShareHealthDataWithAI, get: { Config.shareHealthDataWithAI })
        assertRoundTrip("agentModelDownloaded", set: Config.setAgentModelDownloaded, get: { Config.agentModelDownloaded })
        assertRoundTrip("localAgentEnabled", set: Config.setLocalAgentEnabled, get: { Config.localAgentEnabled })
        assertRoundTrip("visualStateInjectThumbnails", set: Config.setVisualStateInjectThumbnails, get: { Config.visualStateInjectThumbnails })
    }

    /// A raw value written under the legacy key (as the old setter did) is read by the new property —
    /// proves the wrapper's key is unchanged, so previously-persisted user settings survive.
    func testLegacyPersistedValuesStillRead() {
        UserDefaults.standard.set(true, forKey: "silentMode")
        XCTAssertTrue(Config.silentMode)
        UserDefaults.standard.set(true, forKey: "accessibilityModeEnabled")
        XCTAssertTrue(Config.accessibilityModeEnabled)
    }

    private func assertRoundTrip(_ key: String, set: (Bool) -> Void, get: () -> Bool,
                                 file: StaticString = #file, line: UInt = #line) {
        set(true)
        XCTAssertTrue(get(), "\(key) should read true after set(true)", file: file, line: line)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "\(key) must persist under its exact key", file: file, line: line)
        set(false)
        XCTAssertFalse(get(), "\(key) should read false after set(false)", file: file, line: line)
    }
}
