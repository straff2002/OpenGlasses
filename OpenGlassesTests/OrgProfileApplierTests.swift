import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan CT P1 — the pure applier: the allow-list, the one direction each key may move, the named
/// drops, the lease bounds, and the precedence order with a synthetic managed layer standing in
/// for the MDM reader that does not ship yet.
final class OrgProfileApplierTests: XCTestCase {

    private let vaults: Set<String> = ["refrigeration", "it_network", "hvac_rtu"]

    private func layer(_ settings: [String: RawSetting], leaseDays: Int = 30,
                       eraseAfterLapseDays: Int? = nil,
                       undeliveredEraseDays: Int? = nil) -> ConfigProfile {
        ConfigProfile(keyId: "test-key", profileId: "p", organizationName: "Northbridge Mechanical",
                      issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: leaseDays,
                      eraseAfterLapseDays: eraseAfterLapseDays,
                      undeliveredEraseDays: undeliveredEraseDays, settings: settings)
    }

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        ProfileApplier.apply(profile: layer(settings), resolvableVaultIds: vaults)
    }

    // MARK: - The allow-list

    /// A secret must be structurally impossible to put in a profile: a QR is a photograph.
    func testNoSettingKeyIsASecret() {
        let secrets = Set(Config.migratableStringSecretKeys + Config.migratableDataSecretKeys)
        let settable = Set(SettingKey.allCases.map(\.rawValue))
        XCTAssertTrue(settable.isDisjoint(with: secrets),
                      "secret keys in SettingKey: \(settable.intersection(secrets).sorted())")
    }

    func testUnknownKeyIsDroppedByName() {
        let result = apply(["anthropicAPIKey": RawSetting(.string("sk-anything"), .default)])
        XCTAssertEqual(result.drops, [.init(key: "anthropicAPIKey", reason: .unknownKey)])
        XCTAssertTrue(result.startingValues.isEmpty && result.owned.isEmpty && result.ceilings.isEmpty)
    }

    // MARK: - Direction

    func testEveryCeilingPinsOneWayAndRefusesTheOther() {
        for key in SettingKey.allCases {
            guard case .ceiling(let pinnedTo) = key.kind else { continue }

            let allowed = apply([key.rawValue: RawSetting(.bool(pinnedTo), .ceiling)])
            XCTAssertEqual(allowed.ceilings[key], .bool(pinnedTo), key.rawValue)
            XCTAssertTrue(allowed.drops.isEmpty, key.rawValue)

            let widened = apply([key.rawValue: RawSetting(.bool(!pinnedTo), .ceiling)])
            XCTAssertNil(widened.ceilings[key], key.rawValue)
            XCTAssertEqual(widened.drops, [.init(key: key.rawValue, reason: .wrongDirection)], key.rawValue)
        }
    }

    func testThePrivacyFilterCanBePinnedOnAndNeverOff() {
        XCTAssertEqual(SettingKey.privacyFilterEnabled.kind, .ceiling(pinnedTo: true))
        XCTAssertEqual(SettingKey.organizationAllowsUnsignedVaults.kind, .ceiling(pinnedTo: false))
        XCTAssertEqual(SettingKey.remoteInvokeCaptureEnabled.kind, .ceiling(pinnedTo: false))
    }

    func testACeilingOnlyKeyRefusesAStartingValue() {
        let result = apply(["privacyFilterEnabled": RawSetting(.bool(true), .default)])
        XCTAssertEqual(result.drops, [.init(key: "privacyFilterEnabled",
                                            reason: .dispositionNotAllowed(.default))])
    }

    func testAStartingValueKeyCannotBePinnedYet() {
        let result = apply(["fieldAssistEnabled": RawSetting(.bool(true), .ceiling)])
        XCTAssertEqual(result.drops, [.init(key: "fieldAssistEnabled",
                                            reason: .dispositionNotAllowed(.ceiling))])
    }

    func testUnknownDispositionIsDroppedByName() {
        let result = apply(["mcpServerEnabled": RawSetting(value: .bool(false), disposition: "lock")])
        XCTAssertEqual(result.drops, [.init(key: "mcpServerEnabled", reason: .unknownDisposition("lock"))])
    }

    // MARK: - Types and content

    func testWrongTypeIsDroppedByName() {
        let result = apply(["fieldAssistEnabled": RawSetting(.string("yes"), .default),
                            "organizationReportRecipients": RawSetting(.string("office@example.com"), .default)])
        XCTAssertEqual(result.drops, [
            .init(key: "fieldAssistEnabled", reason: .wrongType(expected: .bool)),
            .init(key: "organizationReportRecipients", reason: .wrongType(expected: .strings)),
        ])
    }

    /// A value this build cannot read decodes to nothing rather than failing the whole profile.
    func testAnUnreadableValueDecodesAndIsDroppedNotFatal() throws {
        let json = """
        {"format":"openglasses.org-profile","schemaVersion":1,"keyId":"k","profileId":"p",
         "organizationName":"Northbridge","issued":"2026-09-24T00:00:00Z","leaseDays":30,
         "settings":{"fieldAssistEnabled":{"value":1,"disposition":"default"},
                     "privacyFilterEnabled":{"value":true,"disposition":"ceiling"}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(ConfigProfile.self, from: Data(json.utf8))
        let result = ProfileApplier.apply(profile: profile, resolvableVaultIds: vaults)
        XCTAssertEqual(result.drops, [.init(key: "fieldAssistEnabled", reason: .unreadableValue)])
        XCTAssertEqual(result.ceilings[.privacyFilterEnabled], .bool(true))
    }

    func testDefaultVaultMustResolve() {
        let missing = apply(["fieldAssistDefaultVaultId": RawSetting(.string("not_installed"), .default)])
        XCTAssertNil(missing.startingValues[.fieldAssistDefaultVaultId])
        XCTAssertEqual(missing.drops.map(\.key), ["fieldAssistDefaultVaultId"])

        let present = apply(["fieldAssistDefaultVaultId": RawSetting(.string("hvac_rtu"), .default)])
        XCTAssertEqual(present.startingValues[.fieldAssistDefaultVaultId], .string("hvac_rtu"))
    }

    func testContentChecksOnOrganisationValues() {
        let jobKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let good = apply([
            "organizationDisplayName": RawSetting(.string("Northbridge Mechanical"), .default),
            "organizationJobSigningKey": RawSetting(.string(jobKey), .default),
            "organizationJobReportChannel": RawSetting(.string("email"), .default),
            "organizationReportRecipients": RawSetting(.strings(["office@example.com"]), .default),
            "fieldAssistDefaultMode": RawSetting(.string("ai_only"), .default),
        ])
        XCTAssertTrue(good.drops.isEmpty, "\(good.drops)")
        XCTAssertEqual(good.owned.count, 4)

        let bad = apply([
            "organizationDisplayName": RawSetting(.string("   "), .default),
            "organizationJobSigningKey": RawSetting(.string("bm90IGEga2V5"), .default),
            "organizationJobReportChannel": RawSetting(.string("carrier_pigeon"), .default),
            "organizationReportRecipients": RawSetting(.strings(["two words"]), .default),
            "fieldAssistDefaultMode": RawSetting(.string("autopilot"), .default),
        ])
        XCTAssertEqual(bad.drops.count, 5)
        XCTAssertTrue(bad.owned.isEmpty && bad.startingValues.isEmpty)
        for drop in bad.drops {
            guard case .invalidValue = drop.reason else { return XCTFail("\(drop)") }
        }
    }

    // MARK: - Lease and erasure windows

    func testLeaseIsHeldToItsBoundsAndSaysSo() {
        let short = ProfileApplier.apply(profile: layer([:], leaseDays: 1), resolvableVaultIds: vaults)
        XCTAssertEqual(short.leaseDays, 7)
        XCTAssertEqual(short.notices, [.leaseClamped(requested: 1, applied: 7)])

        let long = ProfileApplier.apply(profile: layer([:], leaseDays: 1_000), resolvableVaultIds: vaults)
        XCTAssertEqual(long.leaseDays, 365)
        XCTAssertEqual(long.notices, [.leaseClamped(requested: 1_000, applied: 365)])

        let fine = ProfileApplier.apply(profile: layer([:], leaseDays: 180), resolvableVaultIds: vaults)
        XCTAssertEqual(fine.leaseDays, 180)
        XCTAssertTrue(fine.notices.isEmpty)
    }

    func testErasureWindows() {
        let absent = ProfileApplier.apply(profile: layer([:]), resolvableVaultIds: vaults)
        XCTAssertNil(absent.eraseAfterLapseDays, "a lapse only ever locks unless the organisation opts in")
        XCTAssertEqual(absent.undeliveredEraseDays, ConfigProfile.defaultUndeliveredEraseDays)

        let set = ProfileApplier.apply(profile: layer([:], eraseAfterLapseDays: 60, undeliveredEraseDays: 14),
                                       resolvableVaultIds: vaults)
        XCTAssertEqual(set.eraseAfterLapseDays, 60)
        XCTAssertEqual(set.undeliveredEraseDays, 14)

        let silly = ProfileApplier.apply(profile: layer([:], eraseAfterLapseDays: 0), resolvableVaultIds: vaults)
        XCTAssertNil(silly.eraseAfterLapseDays)
        XCTAssertEqual(silly.notices, [.erasureWindowIgnored(field: "eraseAfterLapseDays", requested: 0)])
    }

    // MARK: - Precedence: managed > profile > user, ceilings as a final clamp

    func testPrecedence() {
        let profile = layer([
            "organizationDisplayName": RawSetting(.string("From the profile"), .default),
            "fieldAssistDefaultMode": RawSetting(.string("ai_only"), .default),
            "remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling),
        ])
        let managed = layer([
            "organizationDisplayName": RawSetting(.string("From the MDM"), .default),
            "fieldAssistDefaultMode": RawSetting(.string("human_assisted"), .default),
            "mcpServerEnabled": RawSetting(.bool(false), .ceiling),
        ], leaseDays: 90)

        let result = ProfileApplier.apply(profile: profile, managed: managed, resolvableVaultIds: vaults)

        // Managed wins over profile where both set a value.
        XCTAssertEqual(result.owned[.organizationDisplayName], .string("From the MDM"))
        XCTAssertEqual(result.startingValues[.fieldAssistDefaultMode], .string("human_assisted"))
        XCTAssertEqual(result.leaseDays, 90)
        // Ceilings from every layer apply.
        XCTAssertEqual(result.ceilings[.remoteInvokeCaptureEnabled], .bool(false))
        XCTAssertEqual(result.ceilings[.mcpServerEnabled], .bool(false))
        // Reported, never merged silently.
        XCTAssertEqual(result.notices, [.profileUnderManagement])
    }

    func testClampOnReadLeavesThePersonsValueAlone() {
        let result = apply(["remoteInvokeCaptureEnabled": RawSetting(.bool(false), .ceiling),
                            "organizationDisplayName": RawSetting(.string("Northbridge"), .default)])

        // The person had turned capture on; the ceiling wins on read.
        XCTAssertEqual(result.effectiveValue(.remoteInvokeCaptureEnabled, stored: .bool(true)), .bool(false))
        XCTAssertTrue(result.isLocked(.remoteInvokeCaptureEnabled))
        // Profile-owned values win over whatever is stored.
        XCTAssertEqual(result.effectiveValue(.organizationDisplayName, stored: .string("")), .string("Northbridge"))
        // Nothing set: the person's value.
        XCTAssertEqual(result.effectiveValue(.privacyFilterEnabled, stored: .bool(false)), .bool(false))
        XCTAssertFalse(result.isLocked(.privacyFilterEnabled))

        // No profile at all (removed): every stored value comes back untouched.
        let removed = ProfileApplier.apply(profile: nil, resolvableVaultIds: vaults)
        XCTAssertEqual(removed.effectiveValue(.remoteInvokeCaptureEnabled, stored: .bool(true)), .bool(true))
        XCTAssertNil(removed.leaseDays)
    }

    /// A managed *starting value* never outranks a profile *ceiling*: ceilings are a final clamp.
    func testAManagedDefaultCannotLiftAProfileCeiling() {
        let profile = layer(["remoteInvokeObserveEnabled": RawSetting(.bool(false), .ceiling)])
        let managed = layer(["remoteInvokeObserveEnabled": RawSetting(.bool(true), .default)])
        let result = ProfileApplier.apply(profile: profile, managed: managed, resolvableVaultIds: vaults)
        XCTAssertEqual(result.effectiveValue(.remoteInvokeObserveEnabled, stored: .bool(true)), .bool(false))
        XCTAssertEqual(result.drops, [.init(key: "remoteInvokeObserveEnabled",
                                            reason: .dispositionNotAllowed(.default))])
    }
}
