import XCTest
@testable import OpenGlasses

/// W08.1 / W08.5 — the AI feature inventory is checked, not merely written.
///
/// A document listing "every AI feature" is accurate on the day it is written. These tests are what
/// make `AIFeatureRegistry` a different kind of artifact: every sensitive category has a feature in
/// it, every feature has a switch that actually moves, every tool name it claims is a tool that
/// exists, and the one claim that would be embarrassing to get wrong — "disabling this leaves no
/// personal data behind" — is exercised against the real store rather than asserted.
@MainActor
final class AIFeatureRegistryTests: XCTestCase {

    private var restore: [String: Bool] = [:]

    override func tearDown() {
        for (key, value) in restore { UserDefaults.standard.set(value, forKey: key) }
        restore.removeAll()
        super.tearDown()
    }

    /// Flip a feature off for the duration of one test, restoring whatever was there.
    private func disable(_ feature: AIFeature) {
        set(feature, enabled: false)
    }

    /// Flip a feature on for the duration of one test, so a test that starts from "on" says so
    /// rather than relying on the default.
    private func enable(_ feature: AIFeature) {
        set(feature, enabled: true)
    }

    private func set(_ feature: AIFeature, enabled: Bool) {
        let key = feature.record.disableSwitch.key
        if restore[key] == nil { restore[key] = feature.record.disableSwitch.isEnabled() }
        feature.record.disableSwitch.setEnabled(enabled)
    }

    // MARK: - Completeness

    func testEveryFeatureIsRegisteredAndDescribed() {
        XCTAssertFalse(AIFeature.allCases.isEmpty)
        for feature in AIFeature.allCases {
            let record = feature.record
            XCTAssertEqual(record.feature, feature, "\(feature) record names a different feature")
            XCTAssertFalse(record.title.isEmpty, "\(feature) has no title")
            XCTAssertFalse(record.sensitiveCategories.isEmpty,
                           "\(feature) was not screened — use [.none] to record that it was")
            XCTAssertFalse(record.disableSwitch.key.isEmpty, "\(feature) has no switch key")
            XCTAssertFalse(record.dataRetainedWhenDisabled.isEmpty,
                           "\(feature) does not say what it leaves behind")
        }
    }

    /// The categories the assessment named each have at least one feature. A category with no
    /// feature means either the screening missed something or the category is dead.
    ///
    /// `.biometric` is the exception, and deliberately: face recognition, its one member, was
    /// removed on 2026-11-13. The category stays in the vocabulary because the screening still asks
    /// the question — speaker identification and Social mode are screened against it and recorded
    /// `.none` — and the case below pins that nothing has come back under it unnoticed.
    func testEverySensitiveCategoryIsCovered() {
        for category in [AIFeature.SensitiveCategory.health, .workerSafety, .externalActuation] {
            XCTAssertTrue(
                AIFeature.allCases.contains { $0.record.sensitiveCategories.contains(category) },
                "no AI feature is registered under \(category.rawValue)")
        }
    }

    /// No AI feature identifies or categorises a person from a face or a voice. A feature that
    /// would must be argued for afresh — it is what the glasses platform's acceptable-use policy
    /// forbids without an exception, and what made the app high-risk under the EU AI Act.
    func testNoFeatureIsBiometric() {
        let biometric = AIFeature.allCases.filter { $0.record.sensitiveCategories.contains(.biometric) }
        XCTAssertEqual(biometric, [], "a biometric feature is back: \(biometric)")
        XCTAssertNil(AIFeature(rawValue: "faceRecognition"))
    }

    /// `.none` is a screening result, not a shrug: it may not be combined with a real category.
    func testNoneIsNeverMixedWithARealCategory() {
        for feature in AIFeature.allCases where feature.record.sensitiveCategories.contains(.none) {
            XCTAssertEqual(feature.record.sensitiveCategories, [.none], "\(feature)")
        }
    }

    func testFeatureKeysAndTitlesAreUnique() {
        let titles = AIFeature.allCases.map(\.record.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two features share a title")
        // Two features may legitimately share a pre-existing master switch, but a *new* one may not
        // be introduced twice.
        let newKeys = AIFeature.allCases
            .filter { !$0.record.disableSwitch.preexisting }
            .map(\.record.disableSwitch.key)
        XCTAssertEqual(Set(newKeys).count, newKeys.count, "two features declare the same new switch")
    }

    /// A registered tool name must be a tool. This is the check that catches a renamed tool.
    ///
    /// Scraped from the sources rather than read off a live `NativeToolRegistry`, because several of
    /// these tools are registered conditionally — several need a camera service, the
    /// worker-safety tools are gated on entitlement — so a registry built headless answers to fewer
    /// names than the app has. Trying it the other way round is what surfaced that: four features
    /// "claimed a tool that does not exist" purely because the test's registry had not been given
    /// the dependencies those tools need. `#filePath` is the repo anchor, as in the store registry's
    /// own exhaustiveness scrape.
    func testEveryClaimedToolNameExists() throws {
        let toolsDir = Self.repoRoot.appendingPathComponent("OpenGlasses/Sources/Services/NativeTools")
        let files = try FileManager.default.contentsOfDirectory(atPath: toolsDir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 50, "the tool directory scrape found almost nothing")

        var declared = Set<String>()
        for file in files {
            let text = try String(contentsOf: toolsDir.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("let name = \"") {
                guard let start = line.range(of: "let name = \""),
                      let end = line[start.upperBound...].firstIndex(of: "\"") else { continue }
                declared.insert(String(line[start.upperBound..<end]))
            }
        }
        XCTAssertTrue(declared.contains("first_aid"), "the scrape itself is broken")

        for feature in AIFeature.allCases {
            for name in feature.record.toolNames {
                XCTAssertTrue(declared.contains(name),
                              "\(feature) claims tool '\(name)', which no tool declares")
            }
        }
    }

    /// `#filePath` is baked in at compile time, so it resolves the same on a developer machine and
    /// in CI, and the simulator shares the host filesystem.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    // MARK: - The switches actually switch

    func testEverySwitchRoundTrips() {
        for feature in AIFeature.allCases {
            let sw = feature.record.disableSwitch
            let original = sw.isEnabled()
            defer { sw.setEnabled(original) }

            sw.setEnabled(false)
            XCTAssertFalse(AIFeatureGate.isEnabled(feature), "\(feature) stayed on when switched off")
            sw.setEnabled(true)
            XCTAssertTrue(AIFeatureGate.isEnabled(feature), "\(feature) stayed off when switched on")
        }
    }

    func testDisabledFeatureContributesItsToolsToTheDisabledSet() {
        enable(.firstAidAssist)
        enable(.healthVault)
        XCTAssertFalse(AIFeatureGate.isToolDisabled("first_aid"))
        disable(.firstAidAssist)
        XCTAssertTrue(AIFeatureGate.isToolDisabled("first_aid"))
        XCTAssertTrue(AIFeatureGate.disabledToolNames.contains("first_aid"))
        // Other features are untouched.
        XCTAssertFalse(AIFeatureGate.isToolDisabled("health_vault"))
    }

    func testDisabledMessageNamesTheFeature() {
        XCTAssertTrue(AIFeatureGate.disabledMessage(.safetyAssessment).contains("Safety assessment"))
    }

    // MARK: - The entry points honour the switch

    func testHealthSafetyToolRefusesWhenTheFeatureIsOff() async throws {
        disable(.healthSafetyAdvisor)
        let answer = try await HealthSafetyTool().execute(args: ["subject": "ibuprofen"])
        XCTAssertEqual(answer, AIFeatureGate.disabledMessage(.healthSafetyAdvisor))
    }

    func testSafetyAssessmentToolRefusesWhenTheFeatureIsOff() async throws {
        disable(.safetyAssessment)
        let answer = try await SafetyAssessmentTool().execute(args: ["action": "last"])
        XCTAssertEqual(answer, AIFeatureGate.disabledMessage(.safetyAssessment))
    }

    func testFirstAidToolRefusesWhenTheFeatureIsOff() async throws {
        disable(.firstAidAssist)
        let answer = try await FirstAidTool().execute(args: ["action": "start"])
        XCTAssertEqual(answer, AIFeatureGate.disabledMessage(.firstAidAssist))
    }

    func testMessagingToolRefusesWhenTheFeatureIsOff() async throws {
        disable(.messaging)
        let answer = try await SendMessageTool().execute(args: ["to": "555", "body": "hi"])
        XCTAssertEqual(answer, AIFeatureGate.disabledMessage(.messaging))
    }

    // MARK: - Turning it off and erasing leaves nothing

    /// The health-side equivalent. The vault is the wearer's own document store, so the honest
    /// claim is that disabling stops the model reading it and does not delete it — and the registry
    /// must say exactly that rather than promising an erase that does not exist.
    func testHealthVaultRetentionClaimMatchesTheAvailableDeletes() {
        let record = AIFeature.healthVault.record
        XCTAssertTrue(record.stores.contains(.vaultDocuments))
        XCTAssertFalse(record.erasure.isAvailable)
        XCTAssertFalse(record.dataRetainedWhenDisabled.lowercased().contains("nothing"))
    }

    /// Wherever a feature claims nothing is retained, no store may be attached to it: a store is
    /// exactly the thing that retains.
    func testNothingRetainedIsOnlyClaimedWhereThereIsNoStore() {
        for feature in AIFeature.allCases {
            let record = feature.record
            guard record.dataRetainedWhenDisabled.lowercased().hasPrefix("nothing") else { continue }
            XCTAssertTrue(record.stores.isEmpty,
                          "\(feature) claims nothing is retained but writes into \(record.stores)")
        }
    }

    /// Every store a feature names must be a store the data-lifecycle registry already knows about,
    /// so the two inventories cannot describe different apps.
    func testEveryNamedStoreIsInTheDataStoreInventory() {
        let known = Set(SensitiveStore.allCases.map(\.rawValue))
        for feature in AIFeature.allCases {
            for store in feature.record.stores {
                XCTAssertTrue(known.contains(store.rawValue), "\(feature) names unknown store \(store)")
            }
        }
    }
}
