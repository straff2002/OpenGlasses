import XCTest
@testable import OpenGlasses

/// Plan LR P0 — `CompanyVaultPlan`: every decision about a company's vaults, headless.
final class CompanyVaultPlanTests: XCTestCase {

    typealias Plan = CompanyVaultPlan
    let gb: Int64 = 1_073_741_824

    func vault(_ id: String = "lennox", version: String = "4", size: Int = 1_000_000, minAppBuild: Int? = nil) -> CompanyVaultCatalog.Vault {
        .init(id: "com.openglasses.vault." + id, vaultId: id, version: version, name: id.capitalized, summary: nil,
              author: nil, minAppBuild: minAppBuild, sizeBytes: size, downloadURL: "https://licence.example.test/\(id).zip",
              sha256: String(repeating: "a", count: 64), packSignature: "s")
    }

    func manual(_ name: String, in vaultId: String = "lennox", revision: Character = "1", size: Int = 60_000_000) -> CompanyVaultCatalog.Manual {
        .init(vaultId: vaultId, fileName: name, revision: String(repeating: revision, count: 64), sizeBytes: size,
              sealedSha256: String(repeating: "c", count: 64), downloadURL: "https://licence.example.test/m/\(name)", kind: .pdf)
    }

    func catalog(_ vaults: [CompanyVaultCatalog.Vault], _ manuals: [CompanyVaultCatalog.Manual] = [],
                 anyNetwork: Bool = false, problems: [String: String] = [:]) -> CompanyVaultCatalog.Verified {
        .init(profileId: "p", generation: 2, issued: Date(), manualsOnAnyNetwork: anyNetwork, vaults: vaults, manuals: manuals,
              problems: problems)
    }

    func installed(_ vaults: [String: String] = [:], manuals: [String: [String: String]] = [:]) -> Plan.Installed {
        .init(vaults: vaults.mapValues { .init(packId: "com.openglasses.vault." + ($0.split(separator: "@").first.map(String.init) ?? ""), version: String($0.split(separator: "@").last ?? "")) },
              manuals: manuals)
    }

    /// `vaults` is vault id → "vaultid@version" so a pack id can be told from the version.
    func installed(_ pairs: [(String, String)], manuals: [String: [String: String]] = [:]) -> Plan.Installed {
        installed(Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, "\($0.0)@\($0.1)") }), manuals: manuals)
    }

    func conditions(job: Plan.Job = .none, network: Plan.Network = .unmetered, downloadNow: Set<String> = [],
                    free: Int64 = 50 * 1_073_741_824, build: Int = 680, minAppBuild: Int? = nil) -> Plan.Conditions {
        .init(job: job, network: network, downloadNow: downloadNow, freeBytes: free, currentBuild: build, minAppBuild: minAppBuild)
    }

    // MARK: - Vaults

    func testANewVaultInstallsAndItsManualsFollow() {
        let wiring = manual("Wiring.pdf")
        XCTAssertEqual(Plan.steps(installed: .init(), catalog: catalog([vault()], [wiring]), conditions: conditions()),
                       [.install(vault()), .addManual(wiring)])
    }

    func testANewVersionUpdatesAndTheSameVersionDoesNothing() {
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "3")]), catalog: catalog([vault()]), conditions: conditions()),
                       [.update(vault(), from: "3")])
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4")]), catalog: catalog([vault()]), conditions: conditions()), [])
    }

    func testAVaultTheCompanyRemovedLeaves() {
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4"), ("trane", "1")]), catalog: catalog([vault()]),
                                  conditions: conditions()),
                       [.remove(vaultId: "trane")])
    }

    func testARowThePhoneRefusedIsNotARemoval() {
        XCTAssertEqual(Plan.steps(installed: installed([("trane", "1")], manuals: ["trane": ["A.pdf": "x"]]),
                                  catalog: catalog([], problems: ["trane": "too big"]), conditions: conditions()), [])
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4")], manuals: ["lennox": ["Huge.pdf": "x"]]),
                                  catalog: catalog([vault()], problems: ["lennox": "Huge is too big"]), conditions: conditions()), [],
                       "a manual row refused is not a manual removed")
    }

    // MARK: - Never mid-job

    func testAnOpenJobHoldsAnUpdateARemovalAndManualChangesToItsVault() {
        let job = conditions(job: .open(vaultId: "lennox"))
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "3")]), catalog: catalog([vault()], [manual("W.pdf")]), conditions: job),
                       [.waitForJob(vaultId: "lennox", version: "4", removal: false)])
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4")]), catalog: catalog([]), conditions: job),
                       [.waitForJob(vaultId: "lennox", version: nil, removal: true)])
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4")], manuals: ["lennox": ["Old.pdf": "x"]]),
                                  catalog: catalog([vault()], [manual("W.pdf")]), conditions: job),
                       [.waitForJob(vaultId: "lennox", version: nil, removal: false)])
    }

    func testANewVaultOrAnotherVaultsManualMayArriveDuringAJob() {
        let job = conditions(job: .open(vaultId: "lennox"))
        let trane = vault("trane", version: "1")
        let traneManual = manual("T.pdf", in: "trane")
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "4")]), catalog: catalog([vault(), trane], [traneManual]),
                                  conditions: job),
                       [.install(trane), .addManual(traneManual)])
    }

    func testAJobOnAnUnknownVaultHoldsEveryChange() {
        XCTAssertEqual(Plan.steps(installed: installed([("lennox", "3")]), catalog: catalog([vault()]),
                                  conditions: conditions(job: .open(vaultId: nil))),
                       [.waitForJob(vaultId: "lennox", version: "4", removal: false)])
    }

    // MARK: - Manuals

    func testOnlyTheManualThatChangedMoves() {
        let a = manual("A.pdf"), b = manual("B.pdf", revision: "2"), c = manual("C.pdf")
        let have = installed([("lennox", "4")], manuals: ["lennox": ["A.pdf": a.revision, "B.pdf": String(repeating: "1", count: 64),
                                                                     "Gone.pdf": "x"]])
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [a, b, c]), conditions: conditions()),
                       [.removeManual(vaultId: "lennox", fileName: "Gone.pdf"),
                        .replaceManual(b, previousRevision: String(repeating: "1", count: 64)),
                        .addManual(c)])
    }

    func testManualsWaitForWiFiUnlessTheCompanyOrTheTechnicianSaysOtherwise() {
        let w = manual("Wiring.pdf")
        let have = installed([("lennox", "4")])
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [w]), conditions: conditions(network: .metered)),
                       [.waitForWiFi(vaultId: "lennox", bytes: 60_000_000)])
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [w], anyNetwork: true),
                                  conditions: conditions(network: .metered)), [.addManual(w)])
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [w]),
                                  conditions: conditions(network: .metered, downloadNow: ["lennox"])), [.addManual(w)])
        // Vault core files use any network.
        XCTAssertEqual(Plan.steps(installed: .init(), catalog: catalog([vault()], [w]), conditions: conditions(network: .metered)),
                       [.install(vault()), .waitForWiFi(vaultId: "lennox", bytes: 60_000_000)])
    }

    func testAManualSetNeedsTwiceItsSizePlusAGigabyte() {
        let w = manual("Wiring.pdf", size: 200_000_000)
        let have = installed([("lennox", "4")])
        let need = Int64(400_000_000) + gb
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [w]), conditions: conditions(free: need - 420_000_000)),
                       [.notEnoughSpace(vaultId: "lennox", shortfall: 420_000_000)])
        XCTAssertEqual(Plan.steps(installed: have, catalog: catalog([vault()], [w]), conditions: conditions(free: need)), [.addManual(w)])
    }

    func testSpaceIsCountedAcrossVaults() {
        let a = manual("A.pdf", size: 100_000_000), b = manual("B.pdf", in: "trane", size: 100_000_000)
        let free = Int64(200_000_000) + gb + 50_000_000
        let steps = Plan.steps(installed: installed([("lennox", "4"), ("trane", "1")]),
                               catalog: catalog([vault(), vault("trane", version: "1")], [a, b]), conditions: conditions(free: free))
        XCTAssertEqual(steps.first, .addManual(a))
        XCTAssertEqual(steps.last, .notEnoughSpace(vaultId: "trane", shortfall: 50_000_000))
    }

    // MARK: - Builds

    func testBelowTheCatalogsBuildNothingHappens() {
        XCTAssertEqual(Plan.steps(installed: .init(), catalog: catalog([vault()], [manual("W.pdf")]),
                                  conditions: conditions(build: 672, minAppBuild: 680)),
                       [.needsNewerApp(vaultId: nil, minBuild: 680)])
    }

    func testBelowOneVaultsBuildOnlyThatVaultWaits() {
        let newer = vault("trane", version: "1", minAppBuild: 700)
        XCTAssertEqual(Plan.steps(installed: .init(), catalog: catalog([vault(), newer], [manual("T.pdf", in: "trane")]),
                                  conditions: conditions(build: 680)),
                       [.install(vault()), .needsNewerApp(vaultId: "trane", minBuild: 700)])
    }

    // MARK: - Rows and the still-downloading line

    func testTheRowsSayWhatEachVaultIsWaitingFor() {
        var state = CompanyVaultState()
        state.vaults["lennox"] = .init(packId: "com.openglasses.vault.lennox", name: "Lennox", version: "3", updatedAt: Date())
        state.waits["lennox"] = .job(version: "4", removal: false)
        let row = CompanyVaultRow.rows(state: state, catalog: catalog([vault()])).first
        XCTAssertEqual(row?.name, "Lennox")
        XCTAssertEqual(row?.version, "3")
        XCTAssertEqual(row?.status, "Version 4 ready — installs after this job.")

        state.waits["lennox"] = .space(shortfall: 420_000_000)
        XCTAssertEqual(CompanyVaultRow.rows(state: state, catalog: nil).first?.status,
                       "Not enough space for the Lennox manuals: \(ByteCountFormatter.string(fromByteCount: 420_000_000, countStyle: .file)) needed.")
        XCTAssertEqual(CompanyVaultRow.rows(state: state, catalog: nil).first?.isProblem, true)

        state.waits["lennox"] = .wifi(bytes: 60_000_000)
        XCTAssertEqual(CompanyVaultRow.rows(state: state, catalog: nil).first?.offersDownloadNow, true)

        state.waits = [:]
        state.failures["lennox"] = "Couldn't install Lennox: download failed."
        XCTAssertEqual(CompanyVaultRow.rows(state: state, catalog: nil).first?.status, "Couldn't install Lennox: download failed.")

        state.failures = [:]
        state.downloading["lennox"] = ["Wiring"]
        XCTAssertEqual(CompanyVaultRow.rows(state: state, catalog: nil).first?.status, "Downloading Wiring.")
        state.downloading = [:]
        XCTAssertNil(CompanyVaultRow.rows(state: state, catalog: nil).first?.status)
    }

    func testAnAnswerSaysAManualIsStillDownloading() {
        XCTAssertNil(CompanyVaultDownloads.promptNote(titles: []))
        let note = CompanyVaultDownloads.promptNote(titles: ["SLP99 Wiring"])
        XCTAssertTrue(note?.contains("SLP99 Wiring") ?? false)
        XCTAssertTrue(note?.contains("still downloading") ?? false)
    }

    func testAStateFromBeforeCompanyVaultsReadsAsNone() throws {
        let json = #"{"document":"d","source":"link","enrolmentId":"e","enrolledAt":"2027-01-15T08:00:00Z","priorStartingValues":{},"wroteStartingKeys":[],"activatedLicence":false}"#
        let record = try ProfileVerification.decoder.decode(OrgEnrolmentRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.companyVaults)
        var state = CompanyVaultState()
        state.highWater = 7
        state.vaults["lennox"] = .init(packId: "p", name: "Lennox", version: "4", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        state.waits["lennox"] = .wifi(bytes: 10)
        let round = try ProfileVerification.decoder.decode(CompanyVaultState.self, from: try ProfileVerification.encoder.encode(state))
        XCTAssertEqual(round, state)
        XCTAssertTrue(state.hasPendingWork)
        state.forgetInstalled()
        XCTAssertTrue(state.vaults.isEmpty)
        XCTAssertEqual(state.highWater, 7, "the high-water mark outlives an erasure: an older list stays refused")
    }
}
