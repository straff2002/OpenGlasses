import XCTest
@testable import OpenGlasses

/// Plan KT decision 8 — an organisation profile can pin "Text customers from cards" off, never on;
/// pinned off, a job card offers no text to the customer. And the cards' defaults (§5.6): on with
/// My Day, short night off until asked for and needing Health.
@MainActor
final class PreparedCardPolicyTests: XCTestCase {

    private let keys = ["preparedCardCustomerTexts", Config.preparedCardKindKey(.shortNight)]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        PolicyEnvelope.clear()
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Example Plumbing",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testTheSwitchIsACeilingThatCanOnlyTurnCustomerTextsOff() {
        let key = SettingKey.preparedCardCustomerTexts
        XCTAssertEqual(key.kind, .ceiling(pinnedTo: false))
        XCTAssertEqual(apply([key.rawValue: RawSetting(.bool(false), .ceiling)]).ceilings[key], .bool(false))
        let widened = apply([key.rawValue: RawSetting(.bool(true), .ceiling)])
        XCTAssertNil(widened.ceilings[key])
        XCTAssertEqual(widened.drops, [.init(key: key.rawValue, reason: .wrongDirection)])
        XCTAssertEqual(key.ceilingDescription, "My Day cards don't offer to text customers")
    }

    func testPinnedOffAJobCardHasNoTextToTheCustomer() {
        XCTAssertTrue(Config.preparedCardCustomerTexts, "on by default")
        let rules = CardFixtures.rules
        let onMyWay = CardFixtures.at(9, 10)
        func settings() -> PreparedCardSettings {
            var settings = PreparedCardSettings.current(isFieldAssistDay: true, healthAvailable: false)
            settings.draftLanguage = "en-GB"
            return settings
        }
        XCTAssertNotNil(rules.jobOnMyWay(CardFixtures.jobInputs(), now: onMyWay, settings: settings())?.card.draft)

        PolicyEnvelope.install(apply(["preparedCardCustomerTexts": RawSetting(.bool(false), .ceiling)]),
                               organizationName: "Example Plumbing")
        XCTAssertFalse(Config.preparedCardCustomerTexts)
        Config.preparedCardCustomerTexts = true   // a locked switch refuses the write
        XCTAssertFalse(Config.preparedCardCustomerTexts)
        let pinned = rules.jobOnMyWay(CardFixtures.jobInputs(), now: onMyWay, settings: settings())
        XCTAssertNotNil(pinned, "the card still comes, with directions")
        XCTAssertNil(pinned?.card.draft)

        PolicyEnvelope.clear()
        XCTAssertTrue(Config.preparedCardCustomerTexts, "removing the profile lifts it")
    }

    func testShortNightIsOptInAndNeedsHealth() {
        XCTAssertFalse(PreparedCardSettings.current(isFieldAssistDay: false, healthAvailable: true).isEnabled(.shortNight))
        Config.setPreparedCardKind(.shortNight, enabled: true)
        XCTAssertFalse(PreparedCardSettings.current(isFieldAssistDay: false, healthAvailable: false).isEnabled(.shortNight))
        XCTAssertTrue(PreparedCardSettings.current(isFieldAssistDay: false, healthAvailable: true).isEnabled(.shortNight))
    }
}
