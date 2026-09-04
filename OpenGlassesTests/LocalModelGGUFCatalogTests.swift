import XCTest
@testable import OpenGlasses

/// Plan DZ P2 — the bundled GGUF catalog and the rules about what an entry may claim.
///
/// The catalog is data, so these tests are mostly about the *claims*: every entry is pinned to an
/// exact revision, every file carries a real digest and an exact size, and no entry wears a
/// capability badge nobody has demonstrated on a device.
final class LocalModelGGUFCatalogTests: XCTestCase {

    /// The app bundle, located through a class that lives in the app target.
    private var appBundle: Bundle { Bundle(for: LocalModelRepository.self) }

    // MARK: - The shipped catalog

    func testBundledCatalogLoadsWithNothingRejected() throws {
        let url = try XCTUnwrap(appBundle.url(forResource: LocalModelCatalogDocument.resourceName,
                                              withExtension: "json"),
                                "LocalModelCatalog.json should be bundled with the app target")
        let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: Data(contentsOf: url))
        XCTAssertEqual(rejected, [], "a shipped entry that the loader refuses is a shipping mistake")
        XCTAssertEqual(document.version, LocalModelCatalogDocument.currentVersion)
        XCTAssertFalse(document.entries.isEmpty)
    }

    func testEveryEntryIsPinnedDigestedAndInstallable() throws {
        for entry in LocalModelCatalog.bundledGGUFEntries(appBundle) {
            let descriptor = entry.descriptor
            let label = descriptor.id.rawValue

            XCTAssertEqual(descriptor.runtime, .llamaCpp, label)
            XCTAssertTrue(LocalModelRepositoryReference.isValidRevision(descriptor.revision),
                          "\(label): revision must be an exact 40-character commit")
            XCTAssertFalse(descriptor.files.isEmpty, label)
            for file in descriptor.files {
                XCTAssertGreaterThan(file.byteCount, 0, "\(label): \(file.relativePath)")
                XCTAssertTrue(LocalModelRepositoryClient.isSHA256(file.sha256),
                              "\(label): \(file.relativePath) must carry a real SHA-256")
                XCTAssertEqual(LocalModelPath.normalize(file.relativePath),
                               .contained(file.relativePath), label)
            }
            XCTAssertTrue(descriptor.installationFaults().isEmpty, label)
            // The gate the downloader itself applies: a catalog entry must be able to become a plan.
            XCTAssertNotNil(LocalModelDownloadPlan(descriptor: descriptor, origin: .curatedCatalog),
                            "\(label): a curated entry must be plannable")

            // The repository half of the id is a reference this build would accept as an import.
            let repositoryID = String(descriptor.id.rawValue.split(separator: "#").first ?? "")
            XCTAssertEqual(repositoryID, descriptor.repositoryID, label)
            guard case .success = LocalModelRepositoryReference.parse(descriptor.repositoryID) else {
                return XCTFail("\(label): repository id is not a reference this app would accept")
            }
            // And the id survives the round trip through a directory name.
            XCTAssertEqual(LocalModelID(storageComponent: descriptor.id.storageComponent),
                           descriptor.id, label)
        }
    }

    func testNoEntryWearsACapabilityBadgeWithoutDeviceEvidence() {
        for entry in LocalModelCatalog.bundledGGUFEntries(appBundle) {
            if entry.evidence != .deviceVerified {
                XCTAssertEqual(entry.descriptor.capabilities, [.text],
                               "\(entry.descriptor.id.rawValue): badges need fixtures, not a hunch")
            }
        }
    }

    func testShippedContextPolicyStaysWithinWhatTheFileWasTrainedFor() {
        for entry in LocalModelCatalog.bundledGGUFEntries(appBundle) {
            guard let trained = entry.trainedContextTokens else { continue }
            XCTAssertLessThanOrEqual(entry.descriptor.contextLength, trained,
                                     entry.descriptor.id.rawValue)
            XCTAssertGreaterThan(entry.descriptor.contextLength, 0)
        }
    }

    func testEveryEntryDeclaresALicenceItCanName() {
        for entry in LocalModelCatalog.bundledGGUFEntries(appBundle) {
            let license = entry.descriptor.license
            XCTAssertFalse(license.displayName.isEmpty, entry.descriptor.id.rawValue)
            XCTAssertFalse(license.summary.isEmpty, entry.descriptor.id.rawValue)
            if license.requiresAcceptance {
                XCTAssertNotNil(license.revision,
                                "\(entry.descriptor.id.rawValue): acceptance needs a revision to accept")
            }
        }
    }

    func testCuratedEntriesAreFitCheckedLikeAnyOtherModel() throws {
        let entry = try XCTUnwrap(LocalModelCatalog.bundledGGUFEntries(appBundle).first)
        let generous = LocalModelFitReport.make(.init(descriptor: entry.descriptor,
                                                      availableStorageBytes: 64_000_000_000,
                                                      availableProcessBytes: 8_000_000_000))
        XCTAssertTrue(generous.canInstall)
        XCTAssertEqual(generous.downloadBytes, entry.descriptor.files.reduce(0) { $0 + $1.byteCount })

        // A curated entry is not exempt from the storage check.
        let cramped = LocalModelFitReport.make(.init(descriptor: entry.descriptor,
                                                      availableStorageBytes: 1_000,
                                                      availableProcessBytes: 8_000_000_000))
        XCTAssertFalse(cramped.canInstall)
    }

    // MARK: - What the loader refuses

    func testLoaderRefusesEntriesThatOverclaimOrCannotBeVerified() throws {
        let cases: [(name: String, mutate: (inout [String: Any]) -> Void)] = [
            ("tool badge without device evidence", { $0["capabilities"] = ["text", "toolFriendly"] }),
            ("vision badge without device evidence", { $0["capabilities"] = ["text", "vision"] }),
            ("missing digest", { json in
                var files = json["files"] as! [[String: Any]]
                files[0]["sha256"] = ""
                json["files"] = files
            }),
            ("zero size", { json in
                var files = json["files"] as! [[String: Any]]
                files[0]["byteCount"] = 0
                json["files"] = files
            }),
            ("unpinned revision", { $0["revision"] = LocalModelDescriptor.floatingRevision }),
            ("escaping path", { json in
                var files = json["files"] as! [[String: Any]]
                files[0]["relativePath"] = "../escape.gguf"
                json["files"] = files
            }),
            ("acceptance with no licence revision", { json in
                json["license"] = ["displayName": "Custom", "summary": "…",
                                   "requiresAcceptance": true]
            }),
        ]

        for testCase in cases {
            var entry = validEntryJSON
            testCase.mutate(&entry)
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "models": [entry]])
            let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: data)
            XCTAssertTrue(document.entries.isEmpty, testCase.name)
            XCTAssertEqual(rejected.count, 1, testCase.name)
        }
    }

    func testADeviceVerifiedEntryMayCarryItsBadges() throws {
        var entry = validEntryJSON
        entry["capabilities"] = ["text", "toolFriendly"]
        entry["evidence"] = "deviceVerified"
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "models": [entry]])
        let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: data)
        XCTAssertEqual(rejected, [])
        XCTAssertEqual(document.entries.first?.descriptor.capabilities, [.text, .toolFriendly])
    }

    func testDuplicateIDsAndMalformedRowsAreDroppedNotFatal() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "models": [validEntryJSON, validEntryJSON, ["id": "broken"]],
        ])
        let (document, rejected) = try LocalModelCatalogDocument.loadStrict(from: data)
        XCTAssertEqual(document.entries.count, 1)
        XCTAssertEqual(rejected.count, 1, "the malformed row fails to decode and never reaches validation")
        XCTAssertTrue(rejected[0].contains("duplicate id"))
    }

    func testAMissingResourceIsAnEmptyCatalogNotACrash() {
        XCTAssertNil(LocalModelCatalog.bundledGGUFDocument(Bundle(for: XCTestCase.self)))
        XCTAssertTrue(LocalModelCatalog.bundledGGUFEntries(Bundle(for: XCTestCase.self)).isEmpty)
    }

    // MARK: - Helpers

    private var validEntryJSON: [String: Any] {
        [
            "id": "owner/repo#model-q4_k_m.gguf",
            "displayName": "Test model",
            "repositoryID": "owner/repo",
            "revision": String(repeating: "b", count: 40),
            "quantization": "Q4_K_M",
            "capabilities": ["text"],
            "contextLength": 4096,
            "estimatedWeightsBytes": 1_000,
            "estimatedWorkingBytes": 2_000,
            "minimumHeadroomBytes": 0,
            "files": [["relativePath": "model-q4_k_m.gguf",
                       "byteCount": 1_000,
                       "sha256": String(repeating: "a", count: 64),
                       "role": "weights"]],
            "license": ["displayName": "Apache License 2.0", "summary": "Permissive.",
                        "requiresAcceptance": false,
                        "revision": String(repeating: "b", count: 40)],
            "notes": "Test",
            "minimumRAMGB": 4,
            "evidence": "fileMetadataOnly",
        ]
    }
}
