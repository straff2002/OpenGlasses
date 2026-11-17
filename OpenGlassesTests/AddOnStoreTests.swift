import XCTest
@testable import OpenGlasses

/// Plan GF P2 — the installed add-ons: exact bytes kept, salvage semantics on the record, version
/// rules, removal, provenance for self-built add-ons, and trust resolved again from the stored
/// envelope rather than taken from the record.
@MainActor
final class AddOnStoreTests: XCTestCase {

    private var root: URL!
    private var directory: URL { root.appendingPathComponent("addons", isDirectory: true) }
    private var backups: URL { root.appendingPathComponent("recovery", isDirectory: true) }

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AddOnStoreTests_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeStore(keys: @escaping @MainActor () -> AddOnStore.TrustKeys = { .init() }) -> AddOnStore {
        AddOnStore(directory: directory, trustKeys: keys, backupDirectory: backups)
    }

    private func candidate(_ data: Data, context: AddOnAdmission.Context = .init()) throws -> AddOnCandidate {
        try XCTUnwrap(AddOnAdmission.review(data, installed: { _ in nil }, context: context).candidate)
    }

    private var currencyData: Data { Data(RecipeAddOnFixtures.currency.utf8) }

    // MARK: - Install

    func testInstallKeepsTheExactBytesAndARecord() throws {
        let store = makeStore()
        let result = store.install(try candidate(currencyData), origin: .installed(via: .link))
        let row = try result.get()
        XCTAssertEqual(row.id, "dev.frankfurter.currency")
        XCTAssertEqual(row.version, "1.0.0")
        XCTAssertTrue(row.enabled)
        XCTAssertFalse(row.editedOnPhone)
        XCTAssertEqual(row.skillNames, ["convert_currency"])
        XCTAssertEqual(row.origin, .installed(via: .link))
        XCTAssertEqual(store.fileBytes(id: row.id), currencyData, "the file is stored byte for byte")
        XCTAssertEqual(store.exportData(id: row.id), currencyData)
        let loaded = try store.loaded(id: row.id).get()
        XCTAssertEqual(loaded.trust, .community)
        XCTAssertEqual(loaded.manifest.name, "Currency")
    }

    func testTheRecordSurvivesARelaunch() throws {
        let store = makeStore()
        store.install(try candidate(currencyData), origin: .installed(via: .file))
        let again = makeStore()
        XCTAssertEqual(again.installed.map(\.id), ["dev.frankfurter.currency"])
        XCTAssertEqual(again.installed.first?.origin, .installed(via: .file))
        XCTAssertNotNil(try? again.loaded(id: "dev.frankfurter.currency").get())
    }

    // MARK: - Versions

    func testTheSameOrAnOlderVersionIsRefusedAndANewerOneReplaces() throws {
        let store = makeStore()
        let first = try store.install(try candidate(AddOnSigningFixtures.file(version: "1.2.0")),
                                      origin: .installed(via: .link), now: Date(timeIntervalSince1970: 100)).get()
        XCTAssertEqual(store.install(try candidate(AddOnSigningFixtures.file(version: "1.2.0")),
                                     origin: .installed(via: .link)),
                       .failure(.notNewer(installed: "1.2.0")))
        XCTAssertEqual(store.install(try candidate(AddOnSigningFixtures.file(version: "1.1.9")),
                                     origin: .installed(via: .link)),
                       .failure(.notNewer(installed: "1.2.0")))
        store.setEnabled(false, id: first.id)
        let updated = try store.install(try candidate(AddOnSigningFixtures.file(version: "1.10.0")),
                                        origin: .installed(via: .link), now: Date(timeIntervalSince1970: 200)).get()
        XCTAssertEqual(updated.version, "1.10.0")
        XCTAssertEqual(updated.installedAt, first.installedAt, "first installed stays the first install")
        XCTAssertEqual(updated.updatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertTrue(updated.enabled, "an update the wearer accepted is on")
        XCTAssertEqual(store.installed.count, 1)
    }

    func testVersionPrecedence() {
        XCTAssertTrue(AddOnVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(AddOnVersion.isNewer("2.0.0", than: "2.0.0-rc.1"))
        XCTAssertTrue(AddOnVersion.isNewer("1.0.0-rc.2", than: "1.0.0-rc.1"))
        XCTAssertTrue(AddOnVersion.isNewer("1.0.0-rc.1", than: "1.0.0-beta"))
        XCTAssertFalse(AddOnVersion.isNewer("1.0.0+build.2", than: "1.0.0+build.1"), "build metadata is ignored")
        XCTAssertFalse(AddOnVersion.isNewer("not.a.version", than: "1.0.0"), "a malformed version is never newer")
    }

    // MARK: - Salvage semantics

    func testOneBadRecordIsDroppedNotTheList() throws {
        let store = makeStore()
        store.install(try candidate(currencyData), origin: .installed(via: .link))
        let stateURL = directory.appendingPathComponent("state.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [Any])
        rows.append(["id": 42, "nonsense": true])
        try JSONSerialization.data(withJSONObject: rows).write(to: stateURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.installed.map(\.id), ["dev.frankfurter.currency"])
        let backedUp = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        XCTAssertEqual(backedUp.filter { $0.hasPrefix("addons-") }.count, 1, "the original blob was backed up first")
        XCTAssertTrue(reloaded.isWritable)
    }

    func testAnUndecodableBlobStartsEmptyAndIsBackedUp() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = makeStore()
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backups.path).count, 1)
    }

    // MARK: - Removal and damage

    func testRemoveDeletesTheAddOnsFolder() throws {
        let store = makeStore()
        store.install(try candidate(currencyData), origin: .installed(via: .link))
        let folder = directory.appendingPathComponent("dev.frankfurter.currency")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        store.remove(id: "dev.frankfurter.currency")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertTrue(makeStore().installed.isEmpty)
    }

    func testRemoveAllEmptiesTheStore() throws {
        let store = makeStore()
        store.install(try candidate(currencyData), origin: .installed(via: .link))
        store.install(try candidate(AddOnSigningFixtures.file()), origin: .installed(via: .file))
        store.removeAll()
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertTrue(makeStore().installed.isEmpty)
    }

    func testAMissingFileIsShownButNeverLoaded() throws {
        let store = makeStore()
        store.install(try candidate(currencyData), origin: .installed(via: .link))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("dev.frankfurter.currency/addon.json"))
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.installed.count, 1, "the record stays, so the wearer can see it and remove it")
        XCTAssertEqual(reloaded.loaded(id: "dev.frankfurter.currency"), .failure(.fileMissing))
        XCTAssertTrue(reloaded.loadedAddOns().isEmpty)
    }

    func testAnIDThatIsNotReverseDNSNeverBecomesAPath() throws {
        let bytes = RecipeAddOnFixtures.file(skills: [RecipeAddOnFixtures.skill(steps: [["say": "Hi."]])],
                                             overrides: ["id": "../escape"])
        let manifest = try RecipeAddOnManifest.decode(bytes)
        let forged = AddOnCandidate(manifest: manifest, fileBytes: bytes, envelopeBytes: nil,
                                    trust: .community, signatureFailure: nil)
        XCTAssertEqual(makeStore().install(forged, origin: .installed(via: .file)), .failure(.invalidID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
    }

    // MARK: - Provenance

    func testSelfBuiltProvenanceIsStoreMetadataNotTheFile() throws {
        let provenance = SelfBuiltAddOnProvenance(sessionID: "session-1", goal: "the tide at the coast",
                                                  builtAt: Date(timeIntervalSince1970: 1_794_000_000))
        let store = makeStore()
        let bytes = AddOnSigningFixtures.file(id: "local.assistant.tide")
        store.install(try candidate(bytes), origin: .selfBuilt(provenance))

        let reloaded = makeStore()
        let row = try XCTUnwrap(reloaded.record(id: "local.assistant.tide"))
        XCTAssertTrue(row.isBuiltByAssistant)
        XCTAssertEqual(row.selfBuiltProvenance, provenance)
        XCTAssertEqual(reloaded.provenance(id: row.id), .selfBuilt(provenance))
        XCTAssertEqual(reloaded.fileBytes(id: row.id), bytes, "the file stays a plain add-on file")
        XCTAssertNil(String(data: bytes, encoding: .utf8)?.range(of: "session-1"))
    }

    // MARK: - Trust

    func testASignedAddOnExportsItsEnvelopeUntilItIsEdited() throws {
        let key = AddOnSigningFixtures.KeyPair()
        let vendorKeys = [AddOnSigningFixtures.vendorKeyID: key.publicBase64]
        let envelope = try AddOnSigningFixtures.vendorEnvelope(AddOnSigningFixtures.file(), key: key)
        let store = makeStore(keys: { .init(vendorKeys: vendorKeys, trustedOrganisations: [:]) })
        let signed = try candidate(envelope, context: .init(vendorKeys: vendorKeys))
        XCTAssertEqual(signed.trust, .vendorSigned)
        store.install(signed, origin: .installed(via: .gallery))
        XCTAssertEqual(store.trust(id: "org.example.test"), .vendorSigned)
        XCTAssertEqual(store.exportData(id: "org.example.test"), envelope)

        let edited = AddOnSigningFixtures.file(version: "1.0.1")
        let editCandidate = AddOnCandidate(manifest: try RecipeAddOnManifest.decode(edited), fileBytes: edited,
                                           envelopeBytes: nil, trust: .community, signatureFailure: nil)
        let row = try store.saveEdit(editCandidate).get()
        XCTAssertTrue(row.editedOnPhone)
        XCTAssertEqual(row.trustAtInstall, .community)
        XCTAssertEqual(store.trust(id: "org.example.test"), .community, "an edit drops the signature")
        XCTAssertEqual(store.exportData(id: "org.example.test"), edited)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("org.example.test/signed.json").path))
    }

    func testAnOrganisationAddOnStopsLoadingWhenItsOrganisationLeaves() throws {
        let key = AddOnSigningFixtures.KeyPair()
        var orgs = ["acme-heating": key.publicBase64]
        let bytes = AddOnSigningFixtures.file(reserved: [.parts])
        let envelope = try AddOnSigningFixtures.orgEnvelope(bytes, key: key, organizationID: "acme-heating")
        let store = makeStore(keys: { .init(vendorKeys: [:], trustedOrganisations: orgs) })
        let context = AddOnAdmission.Context(vendorKeys: [:], trustedOrganisations: orgs,
                                             policy: .init(ceiling: .noCeiling, enrolledOrganizationID: "acme-heating"))
        store.install(try candidate(envelope, context: context), origin: .installed(via: .organisation))
        XCTAssertEqual(store.trust(id: "org.example.test"), .organisationSigned(organizationID: "acme-heating"))

        orgs = [:]
        store.refreshTrust()
        guard case .failure(.noLongerValid(let issues)) = store.loaded(id: "org.example.test") else {
            return XCTFail("a demoted file holding a reserved capability must not load")
        }
        XCTAssertTrue(issues.contains { $0.contains(RecipeAddOnIssue.Code.reservedCapabilityNeedsSignature.rawValue) })
        XCTAssertTrue(store.loadedAddOns().isEmpty)
    }

    func testAStoredEnvelopeThatNoLongerMatchesTheFileIsCommunity() throws {
        let key = AddOnSigningFixtures.KeyPair()
        let vendorKeys = [AddOnSigningFixtures.vendorKeyID: key.publicBase64]
        let envelope = try AddOnSigningFixtures.vendorEnvelope(AddOnSigningFixtures.file(), key: key)
        let store = makeStore(keys: { .init(vendorKeys: vendorKeys, trustedOrganisations: [:]) })
        store.install(try candidate(envelope, context: .init(vendorKeys: vendorKeys)), origin: .installed(via: .link))
        // Someone swaps the stored file for another one; the envelope no longer covers it.
        try AddOnSigningFixtures.file(version: "9.9.9")
            .write(to: directory.appendingPathComponent("org.example.test/addon.json"))
        store.refreshTrust()
        XCTAssertEqual(store.trust(id: "org.example.test"), .community)
    }

    func testTheRegistryRecordsThisStore() {
        let record = SensitiveStore.addOns.record
        XCTAssertEqual(record.owner, "AddOnStore")
        XCTAssertEqual(record.deleteAll, .api("AddOnStore.removeAll()"))
        XCTAssertEqual(record.location, "Documents/addons")
    }
}
