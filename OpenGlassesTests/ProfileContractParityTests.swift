import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan ND P0 — the licence core's profile contract (`ProfileContract`, compiled into this bundle)
/// held to the app's own `SettingKey`, `ConfigProfile` and value rules. The portal builds a company's
/// settings editor on the contract, so a drift here is a portal that offers a setting the phone drops,
/// or lets through a value the phone then refuses.
final class ProfileContractParityTests: XCTestCase {

    // MARK: - The allow-list

    private func contractKind(_ kind: SettingKey.Kind) -> String {
        func type(_ type: SettingKey.ValueType) -> String {
            switch type { case .bool: return "bool"; case .string: return "string"; case .strings: return "strings" }
        }
        switch kind {
        case .profileOwned(let t): return "owned:\(type(t))"
        case .ceiling(let pinned): return "ceiling:\(pinned)"
        case .stringCeiling(let pinned): return "stringCeiling:\(pinned)"
        case .startingValue(let t): return "default:\(type(t))"
        }
    }

    func testTheAllowListIsEverySettingKeyWithItsKindAndDirection() {
        let app = Dictionary(uniqueKeysWithValues: SettingKey.allCases.map { ($0.rawValue, contractKind($0.kind)) })
        XCTAssertEqual(ProfileContract.allowList.count, SettingKey.allCases.count)
        for (key, kind) in app {
            XCTAssertEqual(ProfileContract.allowList[key], kind, "\(key) differs between the app and the contract")
        }
        for key in ProfileContract.allowList.keys {
            XCTAssertNotNil(SettingKey(rawValue: key), "\(key) is in the contract but not the app")
        }
    }

    func testEveryCeilingIsCheckedOnlyInItsDirection() throws {
        for key in SettingKey.allCases {
            switch key.kind {
            case .ceiling(let pinned):
                XCTAssertNoThrow(try ProfileContract.checkSetting(key.rawValue, .init(value: .bool(pinned), disposition: "ceiling")))
                XCTAssertThrowsError(try ProfileContract.checkSetting(key.rawValue, .init(value: .bool(!pinned), disposition: "ceiling")))
                XCTAssertThrowsError(try ProfileContract.checkSetting(key.rawValue, .init(value: .bool(pinned), disposition: "default")))
            case .stringCeiling(let pinned):
                XCTAssertNoThrow(try ProfileContract.checkSetting(key.rawValue, .init(value: .string(pinned), disposition: "ceiling")))
                XCTAssertThrowsError(try ProfileContract.checkSetting(key.rawValue, .init(value: .string(pinned + "x"), disposition: "ceiling")))
            default:
                continue
            }
        }
    }

    // MARK: - What an administrator may edit

    func testAdministratorsEditOnlyStartingValuesAndTheCompanysOwnValues() {
        let editable = ProfileContract.administratorEditableSettings
        XCTAssertTrue(editable.isSubset(of: Set(ProfileContract.allowList.keys)))
        for name in editable {
            let key = try? XCTUnwrap(SettingKey(rawValue: name))
            switch key?.kind {
            case .ceiling, .stringCeiling: XCTFail("\(name) is a ceiling; ceilings stay the vendor's")
            default: break
            }
        }
        for vendorOnly in ["organizationJobSigningKey", "organizationToolDefinitionsMode",
                           "technicianFullName", "technicianDisplayName", "technicianID"] {
            XCTAssertFalse(editable.contains(vendorOnly), vendorOnly)
        }
        // Every starting value is the administrator's.
        for key in SettingKey.allCases {
            if case .startingValue = key.kind { XCTAssertTrue(editable.contains(key.rawValue), key.rawValue) }
        }
    }

    private var input: ProfileContract.Input {
        ProfileContract.Input(profileId: "fixture", organizationName: "Fixture Ltd", leaseDays: 60,
                              settings: ["fieldAssistDefaultMode": .init(value: .string("ai_only"), disposition: "default"),
                                         "privacyFilterEnabled": .init(value: .bool(true), disposition: "ceiling")],
                              edition: "fieldAssist", lockdown: .init(lock: ["voice"], closedTools: ["web_search"]),
                              profileGeneration: 12)
    }

    func testAnAdministratorsEditMayChangeTheirSettingsAndNothingElse() throws {
        var edited = input
        edited.settings?["fieldAssistDefaultMode"] = .init(value: .string("human_assisted"), disposition: "default")
        edited.settings?["organizationReportRecipients"] = .init(value: .strings(["office@fixture.example"]), disposition: "default")
        edited.lockdown = .init(open: ["voice"], lock: nil, closedTools: ["web_search"])
        edited.aiChoices = ["chatgpt", "local"]
        XCTAssertNoThrow(try ProfileContract.checkAdministratorEdit(from: input, to: edited))

        func refused(_ change: (inout ProfileContract.Input) -> Void, _ field: String) {
            var bad = input
            change(&bad)
            XCTAssertThrowsError(try ProfileContract.checkAdministratorEdit(from: input, to: bad), field) { error in
                XCTAssertTrue((error as? ProfileContract.Invalid)?.message.contains(field) == true, "\(error)")
            }
        }
        refused({ $0.settings?["privacyFilterEnabled"] = nil }, "privacyFilterEnabled")
        refused({ $0.settings?["agentModeEnabled"] = .init(value: .bool(false), disposition: "ceiling") }, "agentModeEnabled")
        refused({ $0.settings?["technicianFullName"] = .init(value: .string("A Person"), disposition: "default") }, "technicianFullName")
        refused({ $0.lockdown = .init(lock: ["voice"], closedTools: []) }, "lockdown.closedTools")
        refused({ $0.leaseDays = 365 }, "leaseDays")
        refused({ $0.edition = nil }, "edition")
        refused({ $0.profileGeneration = 99 }, "profileGeneration")
        refused({ $0.licenceCode = "code" }, "licenceCode")
    }

    func testTheNextGenerationIsAlwaysOneMore() {
        XCTAssertEqual(ProfileContract.nextGeneration(after: nil), 1)
        XCTAssertEqual(ProfileContract.nextGeneration(after: 12), 13)
    }

    func testAssistantChoicesAreSignInOrOnDeviceAndOnlyWithoutAPinnedModel() throws {
        XCTAssertEqual(ProfileContract.knownAssistantChoices,
                       Set(ManagedOnboardingPlan.knownChoices(Array(ProfileContract.knownAssistantChoices)) ?? []))
        for choice in ProfileContract.knownAssistantChoices {
            let provider = try XCTUnwrap(LLMProvider(rawValue: choice))
            XCTAssertFalse(provider.requiresAPIKey, "\(choice) would ask a person for a key")
        }
        XCTAssertNoThrow(try ProfileContract.checkAIChoices(["chatgpt", "local"], pinnedModel: false))
        XCTAssertThrowsError(try ProfileContract.checkAIChoices(["chatgpt"], pinnedModel: true))
        XCTAssertThrowsError(try ProfileContract.checkAIChoices([], pinnedModel: false))
        XCTAssertThrowsError(try ProfileContract.checkAIChoices(["anthropic"], pinnedModel: false))
        XCTAssertThrowsError(try ProfileContract.checkAIChoices(["local", "local"], pinnedModel: false))
        var bad = input
        bad.profileGeneration = 0
        XCTAssertThrowsError(try ProfileContract.check(bad, adminPasscode: false, now: Date()))
    }

    // MARK: - The two new fields reach the phone

    func testTheGenerationAndChoicesTheSignerWritesAreTheOnesThePhoneReads() throws {
        var signed = input
        signed.lockdown = nil
        signed.edition = nil
        signed.aiChoices = ["chatgpt", "local"]
        let document = ProfileContract.document(signed, keyId: "k", issued: Date(timeIntervalSince1970: 1_790_000_000),
                                                adminPasscode: nil)
        let profile = try JSONDecoder().decode(ConfigProfile.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(profile.profileGeneration, 12)
        XCTAssertEqual(profile.aiChoices?.providers, ["chatgpt", "local"])

        var plain = signed
        plain.profileGeneration = nil
        plain.aiChoices = nil
        let bytes = try JSONEncoder().encode(ProfileContract.document(plain, keyId: "k", issued: Date(timeIntervalSince1970: 0), adminPasscode: nil))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("profileGeneration"), "absent fields stay out of the bytes")
        XCTAssertFalse(text.contains("aiChoices"))
    }

    func testMalformedChoicesReadAsNoneRatherThanRefusingTheProfile() throws {
        let json = #"{"format":"openglasses.org-profile","schemaVersion":1,"keyId":"k","profileId":"p","organizationName":"P","issued":0,"leaseDays":30,"settings":{},"aiChoices":{"nope":1}}"#
        let profile = try JSONDecoder().decode(ConfigProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.aiChoices?.providers, [])
        XCTAssertNil(ManagedOnboardingPlan.knownChoices(profile.aiChoices?.providers).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: - Enumerations mirrored in the contract

    func testTheContractsEnumerationsAreTheAppsOwn() {
        XCTAssertEqual(ProfileContract.knownDeliveryChannels, Set(DeliveryChannel.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownToolDefinitionsModes, Set(ToolDefinitionsMode.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownExpertTranscriptRules, Set(ReportTranscriptPolicy.ExpertRule.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownInternalTranscriptRules, Set(ReportTranscriptPolicy.InternalRule.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownStockPlaces, Set(StockPlace.Kind.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownStockConnectors, Set(StockSystemAdapterRegistry.connectorIDs))
        XCTAssertEqual(ProfileContract.knownStockAdjustmentReasons, Set(StockAdjustmentReason.allCases.map(\.rawValue)))
        XCTAssertEqual(ProfileContract.knownManualSearchModels, Set(ManualSearchModel.allCases.map(\.rawValue)))
        for mode in ProfileContract.knownFieldAssistModes { XCTAssertNotNil(FieldSession.Mode(rawValue: mode), mode) }
        XCTAssertEqual(ProfileContract.knownTrades, Set(FieldTrade.allCases.map(\.rawValue)))
    }

    // MARK: - Values: the portal refuses everything the phone would drop

    /// (key, value, does the contract accept it). Rows the contract refuses and the app accepts are
    /// allowed — the portal may be stricter — but never the other way round.
    private static let rows: [(String, ProfileContract.Value, Bool)] = {
        var rows: [(String, ProfileContract.Value, Bool)] = [
            ("workizReportFieldName", .string("Job notes"), true),
            ("workizReportFieldName", .string(""), false),
            ("workizReportFieldName", .string(String(repeating: "a", count: 121)), false),
            ("workizReportFieldName", .string("a\u{7}b"), false),
            ("organizationDisplayName", .string("Northbridge Mechanical"), true),
            ("organizationDisplayName", .string("   "), false),
            ("organizationDisplayName", .string(String(repeating: "n", count: 121)), false),
            ("organizationJobReportChannel", .string("fax"), false),
            ("organizationToolDefinitionsMode", .string("sometimes"), false),
            ("organizationManualSearchModel", .string("best"), false),
            ("expertHandoverTranscript", .string("maybe"), false),
            ("organizationReportTranscriptInternal", .string("ask"), false),
            ("organizationStockPlace", .string("garage"), false),
            ("organizationStockPlace", .string("Van "), false),
            ("stockSystemConnector", .string("shopify"), false),
            ("stockSystemAdjustmentReason", .string("theft"), false),
            ("capturedManualsPolicy", .string("on"), false),
            ("fieldAssistDefaultMode", .string("solo"), false),
            ("expertHandoverRetentionDays", .string("1"), true),
            ("expertHandoverRetentionDays", .string("30"), true),
            ("expertHandoverRetentionDays", .string("0"), false),
            ("expertHandoverRetentionDays", .string("31"), false),
            ("expertHandoverRetentionDays", .string(" 5"), false),
            ("expertHandoverRetentionDays", .string("5d"), false),
            ("organizationReportRecipients", .strings(["office@fixture.example"]), true),
            ("organizationReportRecipients", .strings([]), false),
            ("organizationReportRecipients", .strings((0..<21).map { "o\($0)@fixture.example" }), false),
            ("organizationReportRecipients", .strings(["office @fixture.example"]), false),
            ("organizationAccentColor", .string("#F08A4B"), true),
            ("organizationAccentColor", .string("F08A4B"), false),
            ("accentColorName", .string("#F08A4"), false),
            ("accentColorName", .string("#GGGGGG"), false),
            ("refrigerationUnits", .string("kPa,C,kg"), true),
            ("refrigerationUnits", .string("psi,F,lb"), true),
            ("refrigerationUnits", .string("kpa,c,kg"), false),
            ("refrigerationUnits", .string("atm,C,kg"), false),
            ("refrigerationUnits", .string("kPa,C"), false),
            ("fieldAssistDefaultTrades", .strings(["electrical"]), true),
            ("fieldAssistDefaultTrades", .strings([]), true),
            ("fieldAssistDefaultTrades", .strings(["plumbing"]), false),
            ("organizationJobSigningKey", .string(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()), true),
            ("organizationJobSigningKey", .string("abc"), false),
            ("fieldAssistEnabled", .bool(true), true),
            ("fieldAssistEnabled", .string("yes"), false),
        ]
        for (key, values) in [("organizationJobReportChannel", ProfileContract.knownDeliveryChannels),
                              ("organizationToolDefinitionsMode", ProfileContract.knownToolDefinitionsModes),
                              ("organizationManualSearchModel", ProfileContract.knownManualSearchModels),
                              ("expertHandoverTranscript", ProfileContract.knownExpertTranscriptRules),
                              ("organizationReportTranscriptInternal", ProfileContract.knownInternalTranscriptRules),
                              ("organizationStockPlace", ProfileContract.knownStockPlaces),
                              ("stockSystemConnector", ProfileContract.knownStockConnectors),
                              ("stockSystemAdjustmentReason", ProfileContract.knownStockAdjustmentReasons),
                              ("capturedManualsPolicy", ProfileContract.knownCapturedManualsPolicies),
                              ("fieldAssistDefaultMode", ProfileContract.knownFieldAssistModes)] {
            for value in values.sorted() { rows.append((key, .string(value), true)) }
        }
        return rows
    }()

    private func appAccepts(_ key: String, _ value: ProfileContract.Value) -> Bool {
        let appValue: ProfileValue
        switch value {
        case .bool(let flag): appValue = .bool(flag)
        case .string(let text): appValue = .string(text)
        case .strings(let list): appValue = .strings(list)
        }
        let disposition: ProfileDisposition = ProfileContract.allowList[key]?.hasPrefix("ceiling") == true ? .ceiling : .default
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "P", issued: Date(), leaseDays: 30,
                                    settings: [key: RawSetting(appValue, disposition)])
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
        return result.drops.isEmpty
    }

    private func contractAccepts(_ key: String, _ value: ProfileContract.Value) -> Bool {
        let disposition = ProfileContract.allowList[key]?.hasPrefix("ceiling") == true ? "ceiling" : "default"
        return (try? ProfileContract.checkSetting(key, .init(value: value, disposition: disposition))) != nil
    }

    func testThePortalNeverAcceptsAValueThePhoneWouldDrop() {
        for (key, value, expected) in Self.rows {
            XCTAssertEqual(contractAccepts(key, value), expected, "contract: \(key) = \(value)")
            if contractAccepts(key, value) {
                XCTAssertTrue(appAccepts(key, value), "the portal would accept \(key) = \(value), which the phone drops")
            }
        }
    }

    func testEveryKeyTheContractChecksHasARowAndEveryOtherIsPhoneChecked() {
        let covered = Set(Self.rows.map(\.0))
        for key in ProfileContract.allowList.keys.sorted() {
            switch ProfileContract.allowList[key]!.split(separator: ":").first {
            case "ceiling", "stringCeiling":
                continue // direction-only, covered above
            default:
                // A bool has nothing beyond its type to check.
                if ProfileContract.allowList[key]!.hasSuffix(":bool") { continue }
                XCTAssertTrue(covered.contains(key) || ProfileContract.phoneCheckedSettings.contains(key),
                              "\(key) has no value rows and is not listed as checked on the phone")
            }
        }
    }
}
