import XCTest
@testable import OpenGlasses

/// Plan GF P2 — what an update or an edit changes, as the sheet shows it: domains and permissions
/// added (highlighted) or removed, skills added, removed or changed, and whether it grew.
final class AddOnUpdateDiffTests: XCTestCase {

    private func manifest(network: [String] = ["api.example.org"], location: Bool = false,
                          memory: Bool = false, display: Bool = false,
                          skills: [[String: Any]]? = nil, version: String = "1.0.0",
                          description: String = "A test add-on.") throws -> RecipeAddOnManifest {
        var permissions: [String: Any] = ["network": network]
        if location { permissions["location"] = true }
        if memory { permissions["memory"] = true }
        if display { permissions["display"] = true }
        return try RecipeAddOnFixtures.manifest(
            skills: skills ?? [RecipeAddOnFixtures.skill(steps: [["say": "Done."]])],
            permissions: permissions,
            overrides: ["version": version, "description": description])
    }

    func testAnIdenticalFileHasNoChanges() throws {
        let diff = AddOnUpdateDiff(from: try manifest(), to: try manifest(version: "1.0.1"))
        XCTAssertTrue(diff.isEmpty)
        XCTAssertFalse(diff.permissionsGrew)
        XCTAssertEqual(diff.fromVersion, "1.0.0")
        XCTAssertEqual(diff.toVersion, "1.0.1")
    }

    func testDomainsAddedAndRemovedAreNamedAndAddingOneGrows() throws {
        let diff = AddOnUpdateDiff(from: try manifest(network: ["api.example.org", "old.example.org"]),
                                   to: try manifest(network: ["API.example.org", "new.example.net"]))
        XCTAssertEqual(diff.domainsAdded, ["new.example.net"])
        XCTAssertEqual(diff.domainsRemoved, ["old.example.org"])
        XCTAssertTrue(diff.permissionsGrew)
    }

    func testRemovingADomainAloneDoesNotGrow() throws {
        let diff = AddOnUpdateDiff(from: try manifest(network: ["a.example.org", "b.example.org"]),
                                   to: try manifest(network: ["a.example.org"]))
        XCTAssertEqual(diff.domainsRemoved, ["b.example.org"])
        XCTAssertFalse(diff.permissionsGrew)
        XCTAssertFalse(diff.isEmpty)
    }

    func testPermissionsAddedAndRemoved() throws {
        let rememberSkill = RecipeAddOnFixtures.skill(steps: [
            ["remember": ["key": "last", "value": "x"]], ["say": "Done."],
        ])
        let diff = AddOnUpdateDiff(from: try manifest(display: true),
                                   to: try manifest(location: true, memory: true, skills: [rememberSkill]))
        XCTAssertEqual(diff.permissionsAdded, [.location, .memory])
        XCTAssertEqual(diff.permissionsRemoved, [.display])
        XCTAssertTrue(diff.permissionsGrew)
        XCTAssertEqual(diff.skillsChanged, ["look_up"], "a skill whose steps changed is a changed skill")
    }

    func testSkillsAddedRemovedAndChanged() throws {
        let a = RecipeAddOnFixtures.skill(name: "alpha", steps: [["say": "A."]])
        let b = RecipeAddOnFixtures.skill(name: "bravo", steps: [["say": "B."]])
        let b2 = RecipeAddOnFixtures.skill(name: "bravo", description: "Use when the wearer asks for bravo, now differently.",
                                           steps: [["say": "B."]])
        let c = RecipeAddOnFixtures.skill(name: "charlie", steps: [["say": "C."]])
        let diff = AddOnUpdateDiff(from: try manifest(skills: [a, b]), to: try manifest(skills: [b2, c]))
        XCTAssertEqual(diff.skillsAdded, ["charlie"])
        XCTAssertEqual(diff.skillsRemoved, ["alpha"])
        XCTAssertEqual(diff.skillsChanged, ["bravo"])
        XCTAssertFalse(diff.permissionsGrew, "new skills inside the same permissions don't grow it")
    }

    func testDetailsChangedIsNotAPermissionChange() throws {
        let diff = AddOnUpdateDiff(from: try manifest(), to: try manifest(description: "Something else entirely."))
        XCTAssertTrue(diff.detailsChanged)
        XCTAssertFalse(diff.permissionsGrew)
    }

    // MARK: - On the sheet

    func testTheUpdateSheetHighlightsWhatIsNew() throws {
        let old = try manifest(network: ["api.example.org"])
        let new = try manifest(network: ["api.example.org", "new.example.net"], display: true,
                               skills: [RecipeAddOnFixtures.skill(steps: [
                                   ["display": ["kind": "text", "title": "Hi", "items": ["x"]]], ["say": "Done."],
                               ])], version: "1.1.0")
        let candidate = AddOnCandidate(manifest: new, fileBytes: Data(), envelopeBytes: nil,
                                       trust: .community, signatureFailure: nil)
        let review = AddOnInstallService.Review(id: UUID(), candidate: candidate,
                                                kind: .update(AddOnUpdateDiff(from: old, to: new)),
                                                origin: .installed(via: .link))
        let model = AddOnSheetModel(review: review)
        XCTAssertEqual(model.title, "Update Test add-on?")
        XCTAssertEqual(model.confirmTitle, "Update")
        XCTAssertEqual(model.changes.filter { $0.emphasis == .added }.map(\.text).first,
                       "Now connects to: new.example.net")
        XCTAssertTrue(model.changes.contains { $0.emphasis == .added && $0.text.hasPrefix("New: Show cards") })
        let network = try XCTUnwrap(model.permissions.first { $0.id == "permission-network" })
        XCTAssertEqual(network.emphasis, .added)
        XCTAssertEqual(model.permissions.last?.text, AddOnPermissionSummary.neverLine,
                       "the fixed line is always last")
        XCTAssertTrue(model.badges.isEmpty, "no badge for an unsigned file")
    }

    func testTheInstallSheetShowsEveryDomainAndNoBadgeForCommunity() throws {
        let review = AddOnInstallService.Review(
            id: UUID(),
            candidate: AddOnCandidate(manifest: RecipeAddOnFixtures.currencyManifest, fileBytes: Data(),
                                      envelopeBytes: nil, trust: .community, signatureFailure: .badSignature),
            kind: .install, origin: .installed(via: .link))
        let model = AddOnSheetModel(review: review)
        XCTAssertEqual(model.title, "Install Currency?")
        XCTAssertEqual(model.byline, "By Jo Example · example.org")
        XCTAssertEqual(model.permissions.first?.text, "Connect to: api.frankfurter.dev")
        XCTAssertTrue(model.changes.isEmpty)
        XCTAssertNotNil(model.notice, "a signature that didn't check out is said, not hidden")
        XCTAssertFalse(model.badges.contains(.reviewed))
    }

    func testOnlyAVendorSignatureIsReviewedAndSelfBuiltIsSaid() throws {
        func model(_ trust: AddOnTrustClass, origin: AddOnOrigin) -> AddOnSheetModel {
            AddOnSheetModel(review: .init(id: UUID(),
                                          candidate: .init(manifest: RecipeAddOnFixtures.currencyManifest,
                                                           fileBytes: Data(), envelopeBytes: nil, trust: trust,
                                                           signatureFailure: nil),
                                          kind: .install, origin: origin))
        }
        XCTAssertEqual(model(.vendorSigned, origin: .installed(via: .gallery)).badges, [.reviewed])
        XCTAssertEqual(model(.organisationSigned(organizationID: "acme"), origin: .installed(via: .organisation)).badges,
                       [.organisation])
        let selfBuilt = SelfBuiltAddOnProvenance(sessionID: "s", goal: "g", builtAt: Date())
        XCTAssertEqual(model(.community, origin: .selfBuilt(selfBuilt)).badges, [.builtByAssistant])
        for badge in [AddOnSheetModel.Badge.reviewed, .organisation, .builtByAssistant, .editedOnPhone] {
            XCTAssertNil(badge.text.range(of: "beta", options: .caseInsensitive))
        }
    }
}
