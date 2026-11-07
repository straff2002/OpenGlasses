import XCTest
@testable import OpenGlasses

/// Reserved capabilities: decoded under `permissions`, refused on a community file, allowed on a
/// signed one, shown in plain words only when present, and inert at run time.
final class AddOnReservedCapabilityTests: XCTestCase {

    private typealias F = RecipeAddOnFixtures
    private typealias S = AddOnSigningFixtures
    private typealias Cap = AddOnReservedCapability

    private let signedClasses: [AddOnTrustClass] = [.vendorSigned, .organisationSigned(organizationID: "acme-heating")]

    func testTheNamesAreExactlyThePlansTable() {
        XCTAssertEqual(Cap.allCases.map(\.rawValue), ["credentials", "parts", "workRecord", "office"])
    }

    // MARK: - Decode

    func testEachReservedCapabilityDecodes() throws {
        for cap in Cap.allCases {
            let m = try RecipeAddOnManifest.decode(S.file(reserved: [cap]))
            XCTAssertEqual(m.permissions.reserved, [cap], cap.rawValue)
            XCTAssertEqual(m.permissions.network, ["api.example.org"])
        }
        let all = try RecipeAddOnManifest.decode(S.file(reserved: Cap.allCases))
        XCTAssertEqual(all.permissions.reserved, Set(Cap.allCases))
    }

    func testFalseIsTheSameAsAbsent() throws {
        let data = F.file(skills: [F.skill(steps: [["say": "Done."]])],
                          permissions: ["credentials": false, "office": false])
        let m = try RecipeAddOnManifest.decode(data)
        XCTAssertEqual(m.permissions.reserved, [])
        XCTAssertEqual(RecipeAddOnValidator.validate(m), [])
    }

    func testAReservedCapabilityMustBeABoolean() {
        let data = F.file(skills: [F.skill(steps: [["say": "Done."]])], permissions: ["credentials": ["X-Api-Key"]])
        XCTAssertThrowsError(try RecipeAddOnManifest.decode(data)) { error in
            guard case .malformed(let path, _) = error as? RecipeAddOnDecodeError else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(path.hasSuffix("credentials"), path)
        }
    }

    func testOtherUnknownPermissionsStillRefuse() {
        let data = F.file(skills: [F.skill(steps: [["say": "Done."]])], permissions: ["parts": true, "contacts": true])
        XCTAssertThrowsError(try RecipeAddOnManifest.decode(data)) {
            XCTAssertEqual($0 as? RecipeAddOnDecodeError, .unknownKey(path: "permissions", key: "contacts"))
        }
    }

    // MARK: - Validator

    func testACommunityFileNamingOneIsRefused() throws {
        for cap in Cap.allCases {
            let m = try RecipeAddOnManifest.decode(S.file(reserved: [cap]))
            let issues = RecipeAddOnValidator.validate(m)   // default class: community
            XCTAssertEqual(issues.map(\.code), [.reservedCapabilityNeedsSignature], cap.rawValue)
            XCTAssertEqual(issues.first?.path, "permissions.\(cap.rawValue)")
            XCTAssertEqual(issues.first?.detail, "only a signed add-on may use \(cap.rawValue)")
            XCTAssertEqual(RecipeAddOnValidator.validate(m, trust: .community), issues)
        }
    }

    func testEveryReservedCapabilityIsNamedInOrder() throws {
        let m = try RecipeAddOnManifest.decode(S.file(reserved: [.office, .credentials, .parts, .workRecord]))
        XCTAssertEqual(RecipeAddOnValidator.validate(m).map(\.path),
                       ["permissions.credentials", "permissions.parts", "permissions.workRecord", "permissions.office"])
    }

    func testSignedFilesMayHoldThem() throws {
        let m = try RecipeAddOnManifest.decode(S.file(reserved: Cap.allCases))
        for trust in signedClasses {
            XCTAssertEqual(RecipeAddOnValidator.validate(m, trust: trust), [], "\(trust)")
            XCTAssertTrue(RecipeAddOnValidator.validate(data: S.file(reserved: Cap.allCases), trust: trust).isAccepted)
        }
    }

    func testASignedFileStillGetsEveryOtherCheck() throws {
        // Signing grants reserved capabilities; it does not waive a single format limit.
        let data = F.file(skills: [F.skill(steps: [["http": ["url": "https://evil.example.net/x", "as": "r"]], ["say": "Done."]])],
                          permissions: ["network": ["api.example.org"], "credentials": true])
        for trust in signedClasses {
            XCTAssertEqual(RecipeAddOnValidator.validate(data: data, trust: trust).issues.map(\.code), [.httpHostNotAllowed])
        }
    }

    func testOrdinaryFilesMeanTheSameInEveryClass() throws {
        let m = RecipeAddOnFixtures.currencyManifest
        for trust in [AddOnTrustClass.community] + signedClasses {
            XCTAssertEqual(RecipeAddOnValidator.validate(m, trust: trust), [])
        }
    }

    func testTrustClassFacts() {
        XCTAssertFalse(AddOnTrustClass.community.isSigned)
        XCTAssertFalse(AddOnTrustClass.community.mayHoldReservedCapabilities)
        for trust in signedClasses { XCTAssertTrue(trust.mayHoldReservedCapabilities) }
        XCTAssertEqual(AddOnTrustClass.organisationSigned(organizationID: "acme-heating").organizationID, "acme-heating")
        XCTAssertNil(AddOnTrustClass.vendorSigned.organizationID)
    }

    // MARK: - Summary

    func testSummaryLinesOnlyWhenPresent() throws {
        let plain = AddOnPermissionSummary.lines(for: try RecipeAddOnManifest.decode(S.file()).permissions)
        XCTAssertEqual(plain.map(\.kind), [.network, .never])

        let all = AddOnPermissionSummary.lines(for: try RecipeAddOnManifest.decode(S.file(reserved: Cap.allCases)).permissions)
        XCTAssertEqual(all.map(\.kind), [.network, .credentials, .parts, .workRecord, .office, .never])
        XCTAssertEqual(all.map(\.text), [
            "Connect to: api.example.org",
            "Use a key stored for it on this phone. The key is never shown or spoken.",
            "Look up part numbers in your manuals' parts list",
            "Note parts against the job you're on",
            "Send to your office",
            AddOnPermissionSummary.neverLine,
        ])

        let one = AddOnPermissionSummary.lines(for: try RecipeAddOnManifest.decode(S.file(reserved: [.parts])).permissions)
        XCTAssertEqual(one.map(\.kind), [.network, .parts, .never])
    }

    func testSummaryWordingNamesNoPlanOrInternalType() {
        let banned = [#"\bPlan [A-Z]{1,2}\b"#, #"[a-z][A-Z]"#, "Vault", "Keychain", "Avenkin", "Office"]
        for cap in Cap.allCases {
            for pattern in banned {
                XCTAssertNil(cap.summaryText.range(of: pattern, options: .regularExpression),
                             "\(cap.rawValue): \(cap.summaryText) matches \(pattern)")
            }
        }
    }

    // MARK: - Runner

    func testTheRunnerIsUnchangedByReservedCapabilities() async throws {
        let steps: [[String: Any]] = [
            ["http": ["url": "https://api.example.org/v1/thing", "as": "r"]],
            ["extract": ["from": "r", "jsonpath": "$.name", "as": "name"]],
            ["remember": ["key": "last", "value": "{{name}}"]],
            ["display": ["kind": "text", "title": "Thing", "items": ["{{name}}"]]],
            ["say": "It is {{name}}."],
        ]
        func result(_ reserved: [Cap]) async throws -> (RecipeRunResult, [AddOnHTTPRequest]) {
            var permissions: [String: Any] = ["network": ["api.example.org"], "memory": true, "display": true]
            for cap in reserved { permissions[cap.rawValue] = true }
            let m = try F.manifest(skills: [F.skill(steps: steps)], permissions: permissions)
            let transport = FakeAddOnHTTPTransport(json: #"{"name":"Widget"}"#)
            let r = await RecipeRunner(transport: transport, clock: FakeAddOnClock())
                .run(m, skill: "look_up", arguments: [:], context: F.context)
            return (r, transport.requests)
        }
        let (plain, plainRequests) = try await result([])
        let (reserved, reservedRequests) = try await result(Cap.allCases)
        XCTAssertEqual(plain.outcome, .completed)
        XCTAssertEqual(plain.spokenText, "It is Widget.")
        XCTAssertEqual(reserved, plain)
        XCTAssertEqual(reservedRequests, plainRequests)
        XCTAssertEqual(reservedRequests.first?.headers.keys.sorted(), plainRequests.first?.headers.keys.sorted())
    }
}
