import Foundation
import XCTest
@testable import OpenGlasses

/// Plan IM P0 — the rest of the contract amendment and the model (team-learning §13): a candidate's
/// recording evidence and its `tried`/`outcome`, the manifest's `equipment_types`, a symptom
/// learning bounded to the turn's equipment type, a recollection ranked below a learning seen on a
/// job, and the recalled lead-in. The golden fixtures are `Contracts/fixtures/team-learning-v1/`;
/// every model, identifier and name in them is invented.
@MainActor
final class TeamLearningRecollectionTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: TeamLearningRecollectionTests.self)
            .url(forResource: "team-learning-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    private static func decoded(_ name: String) throws -> LearningBundle {
        switch LearningBundle.decode(try fixture(name)) {
        case .success(let decoded): return decoded.bundle
        case .failure(let refusal): XCTFail("\(name) was refused: \(refusal)"); throw refusal
        }
    }

    private static let reviewer = LearningReview.Approver(name: "Fixture Reviewer", role: "Service Manager")
    private static let reviewerDevice = LearningReview.Context(isReviewerDevice: true)
    private static let now = Date(timeIntervalSince1970: 1_795_600_000)

    // MARK: - Codec

    func testTheFourOriginsTravelAndTheRecollectionCarriesItsRecording() throws {
        let bundle = try Self.decoded("candidates-four-origins-v1.json")
        XCTAssertEqual(bundle.candidates.map(\.origin), [.spoken, .report, .reportReview, .recollection])
        XCTAssertEqual(Set(bundle.candidates.map(\.origin)), Set(LearningCandidate.Origin.allCases),
                       "a fixture for every origin")
        let recalled = bundle.candidates[3]
        XCTAssertEqual(recalled.tried, "Checked the door gasket and the defrost timer first")
        XCTAssertEqual(recalled.outcome, "fixed it most times")
        let recording = try XCTUnwrap(recalled.evidence.recording)
        XCTAssertEqual(recording.recordingID, String(repeating: "b", count: 32))
        XCTAssertEqual(recording.segment, 42..<97)
        XCTAssertNil(bundle.candidates[0].evidence.recording)

        // Round trip: bytes → bundle → bytes → the same bundle.
        guard case .success(let again) = LearningBundle.decode(bundle.encoded()) else { return XCTFail("re-encoded bundle refused") }
        XCTAssertEqual(again.bundle, bundle)

        // The reviewer's store keeps every new field, and sends it back out the same.
        let imported = recalled.candidate(importedFrom: "fixture")
        XCTAssertEqual(imported.tried, recalled.tried)
        XCTAssertEqual(imported.outcome, recalled.outcome)
        XCTAssertEqual(imported.evidence.recording, recording)
        XCTAssertEqual(LearningBundle.Candidate(imported), recalled)
    }

    func testABundleFromBeforeTheAmendmentStillImportsAndEncodesWithoutTheNewKeys() throws {
        let bundle = try Self.decoded("candidates-pre-amendment-v1.json")
        let wire = try XCTUnwrap(bundle.candidates.first)
        XCTAssertNil(wire.tried)
        XCTAssertNil(wire.outcome)
        XCTAssertNil(wire.evidence.recording)
        let candidate = wire.candidate(importedFrom: "fixture")
        XCTAssertEqual(candidate.status, .received)
        XCTAssertEqual(candidate.symptom, "Short cycles")
        let text = String(decoding: bundle.encoded(), as: UTF8.self)
        for key in ["\"tried\"", "\"outcome\"", "\"recording\""] {
            XCTAssertFalse(text.contains(key), "an old-shape candidate is the bytes it was: \(key)")
        }
    }

    func testTheCandidateRecordRoundTripsAndAnOldRecordStillReads() throws {
        var candidate = F.candidate(finding: "Door frame sweats when the heater fuse has gone")
        candidate.tried = "Checked the door gasket"
        candidate.outcome = "worked once"
        let recording = try XCTUnwrap(LearningCandidate.Recording(recordingID: String(repeating: "c", count: 32), segment: 5..<60))
        candidate = LearningCandidate(id: candidate.id, origin: .recollection, sessionId: candidate.sessionId,
                                      jobReference: nil, taskId: nil, vaultId: F.vaultId, equipment: nil,
                                      spokenModel: nil, finding: candidate.finding, symptom: nil, fix: nil,
                                      tried: candidate.tried, outcome: candidate.outcome,
                                      evidence: .init(recording: recording), author: "Fixture Technician",
                                      createdAt: Self.now, redactions: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(LearningCandidate.self, from: encoder.encode(candidate))
        XCTAssertEqual(back, candidate)

        // A record a build before the amendment stored: no tried, outcome or recording.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(F.candidate())) as? [String: Any])
        XCTAssertNil(object["tried"])
        var evidence = try XCTUnwrap(object["evidence"] as? [String: Any])
        XCTAssertNil(evidence["recording"], "an absent recording is not written")
        evidence.removeValue(forKey: "recording")
        object["evidence"] = evidence
        let old = try decoder.decode(LearningCandidate.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.tried)
        XCTAssertNil(old.outcome)
        XCTAssertNil(old.evidence.recording)
    }

    func testARecordingPointsAtANonEmptySegmentOfADay() {
        let id = String(repeating: "d", count: 32)
        XCTAssertNotNil(LearningCandidate.Recording(recordingID: id, segment: 0..<1))
        XCTAssertNotNil(LearningCandidate.Recording(recordingID: id, segment: 0..<86_400))
        XCTAssertNil(LearningCandidate.Recording(recordingID: id, segment: 10..<10), "an empty segment")
        XCTAssertNil(LearningCandidate.Recording(recordingID: id, segment: 0..<86_401), "past a day")
        XCTAssertNil(LearningCandidate.Recording(recordingID: "D" + String(repeating: "d", count: 31), segment: 0..<5))
        XCTAssertNil(LearningCandidate.Recording(recordingID: "dd", segment: 0..<5))
    }

    func testEveryNegativeBundleIsRefusedByName() throws {
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("negative-bundles-v1.json")) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected = try XCTUnwrap(item["refusal"] as? [String: String])
            let bytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["bundle"]))
            guard case .failure(let refusal) = LearningBundle.decode(bytes) else {
                XCTFail("\(name): accepted"); continue
            }
            let (kind, path) = Self.describe(refusal)
            XCTAssertEqual(kind, expected["case"], name)
            XCTAssertEqual(path, expected["path"], name)
        }
    }

    private static func describe(_ refusal: LearningBundle.Refusal) -> (String, String?) {
        switch refusal {
        case .outOfRange(let path): return ("outOfRange", path)
        case .invalidIdentifier(let path): return ("invalidIdentifier", path)
        case .missingKey(let path): return ("missingKey", path)
        case .unknownKey(let path): return ("unknownKey", path)
        case .wrongType(let path): return ("wrongType", path)
        case .controlCharacter(let path): return ("controlCharacter", path)
        case .tooLong(let path, _, _): return ("tooLong", path)
        case .empty(let path): return ("empty", path)
        case .unknownVersion: return ("unknownVersion", nil)
        case .unknownKind: return ("unknownKind", nil)
        default: return ("\(refusal)", nil)
        }
    }

    func testApprovedEntriesOfEveryOriginTravelWithTheirTriedAndOutcome() throws {
        let bundle = try Self.decoded("decisions-four-origins-v1.json")
        let entries = bundle.entries.map { $0.entry() }
        XCTAssertEqual(entries.map(\.origin), [.spoken, .report, .reportReview, .recollection])
        let recalled = entries[3]
        XCTAssertEqual(recalled.tried, "Checked the door gasket and the defrost timer first")
        XCTAssertEqual(recalled.outcome, "fixed it most times")
        XCTAssertNil(recalled.confirmedJobCount, "a recollection was bound to no job")
        XCTAssertEqual(recalled.citationName, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service Manager")
        XCTAssertEqual(entries[0].citationName, "Team learning · QXRT-990 · 2026-11-25 · approved by Service Manager")
        XCTAssertEqual(LearningBundle.Entry(recalled), bundle.entries[3])
    }

    func testTheSymptomSubjectDecodesAsAnEntryAndTheUnsignedBundleRefusesItByName() throws {
        let data = try Self.fixture("decisions-symptom-subject-v1.json")
        let raw = try JSONDecoder().decode(LearningBundle.self, from: data)
        let entry = try XCTUnwrap(raw.entries.first).entry()
        XCTAssertEqual(entry.subject, .symptom(equipmentType: "walk-in cooler", phrase: "Door frame sweats"))
        XCTAssertEqual(entry.origin, .recollection)
        XCTAssertEqual(entry.citationName, "Crew experience · walk-in cooler · 2026-11-25 · approved by Service Manager")
        guard case .failure(.outOfRange("entries[0].subject.kind")) = LearningBundle.decode(data) else {
            return XCTFail("FP's unsigned bundle does not carry a symptom subject (§11)")
        }
    }

    // MARK: - Text and review

    func testTriedAndOutcomeAreCleanedAndBounded() {
        guard case .success(let cleaned) = LearningCandidateText.clean(
            finding: "Heater fuse", symptom: nil, fix: nil, tried: "  Checked\tthe gasket\n", outcome: "worked once") else {
            return XCTFail("refused")
        }
        XCTAssertEqual(cleaned.tried, "Checked the gasket")
        XCTAssertEqual(cleaned.outcome, "worked once")
        XCTAssertEqual(LearningCandidateText.clean(finding: "x", symptom: nil, fix: nil, tried: String(repeating: "t", count: 501)),
                       .failure(.tooLong(.tried, count: 501, limit: 500)))
        XCTAssertEqual(LearningCandidateText.clean(finding: "x", symptom: nil, fix: nil, outcome: String(repeating: "o", count: 121)),
                       .failure(.tooLong(.outcome, count: 121, limit: 120)))
        XCTAssertEqual(LearningCandidateText.clean(finding: "x", symptom: nil, fix: nil, tried: "a\u{202E}b"),
                       .failure(.controlCharacter(.tried)))
        guard case .success(let redacted) = LearningCandidateText.clean(
            finding: "x", symptom: nil, fix: nil, tried: "Emailed fixture.tech@example.com first") else { return XCTFail() }
        XCTAssertFalse(redacted.tried?.contains("@example.com") ?? true)
        XCTAssertTrue(redacted.redactions.contains("email"))
    }

    private func recollection(tried: String? = "Checked the door gasket", outcome: String? = "fixed it most times") -> LearningCandidate {
        LearningCandidate(origin: .recollection, sessionId: "fixture-recording-session", jobReference: nil, taskId: nil,
                          vaultId: F.vaultId, equipment: nil, spokenModel: nil,
                          finding: "Door frame sweats when the heater fuse has gone", symptom: "Door frame sweats",
                          fix: "Replace the heater fuse", tried: tried, outcome: outcome,
                          evidence: .init(recording: LearningCandidate.Recording(recordingID: String(repeating: "e", count: 32),
                                                                                 segment: 42..<97)),
                          author: "Fixture Technician", createdAt: Self.now, redactions: [])
    }

    func testARecollectionIsApprovedWithItsWordsAndNoJob() throws {
        let approval = try LearningReview.approve(recollection(), approver: Self.reviewer,
                                                  subject: .model(modelToken: F.model090),
                                                  context: Self.reviewerDevice, now: Self.now).get()
        XCTAssertEqual(approval.entry.origin, .recollection)
        XCTAssertEqual(approval.entry.tried, "Checked the door gasket")
        XCTAssertEqual(approval.entry.outcome, "fixed it most times")
        XCTAssertNil(approval.entry.sourceJobIDs, "a recollection is bound to no job")
        XCTAssertNil(approval.entry.confirmedJobCount)
        XCTAssertTrue(approval.entry.isCrewExperience)

        // A spoken candidate still counts its job.
        let spoken = try LearningReview.approve(F.candidate(), approver: Self.reviewer,
                                                context: Self.reviewerDevice, now: Self.now).get()
        XCTAssertEqual(spoken.entry.confirmedJobCount, 1)
        XCTAssertEqual(spoken.entry.sourceJobIDs, ["job-1"])

        // Merged into a learning, a recollection confirms no job.
        let merged = try LearningReview.merge(recollection(), into: spoken.entry, approver: Self.reviewer,
                                              context: Self.reviewerDevice).get()
        XCTAssertEqual(merged.entry.confirmedJobCount, 1)
        XCTAssertEqual(merged.entry.sourceJobIDs, ["job-1"])
    }

    func testASymptomSubjectNamesAnEquipmentTypeFromTheClosedList() throws {
        let subject = LearningEntry.Subject.symptom(equipmentType: "WALK-IN  Cooler", phrase: "Door frame sweats")
        let refused = LearningReview.approve(recollection(), approver: Self.reviewer, subject: subject,
                                             context: Self.reviewerDevice, now: Self.now)
        XCTAssertEqual(refused.map(\.entry.id), .failure(.equipmentTypeNotListed("WALK-IN  Cooler")),
                       "with no list, a symptom subject is refused")
        XCTAssertEqual(LearningReview.approve(recollection(), approver: Self.reviewer,
                                              subject: .symptom(equipmentType: "dishwasher", phrase: "Door frame sweats"),
                                              equipmentTypes: ["dryer", "walk-in cooler"],
                                              context: Self.reviewerDevice, now: Self.now).map(\.entry.id),
                       .failure(.equipmentTypeNotListed("dishwasher")))
        let approved = try LearningReview.approve(recollection(), approver: Self.reviewer, subject: subject,
                                                  equipmentTypes: ["dryer", "walk-in cooler"],
                                                  context: Self.reviewerDevice, now: Self.now).get()
        XCTAssertEqual(approved.entry.subject, .symptom(equipmentType: "walk-in cooler", phrase: "Door frame sweats"),
                       "stored in the list's own spelling")
        XCTAssertTrue(LearningReview.Refusal.equipmentTypeNotListed("dishwasher").spoken.contains("dishwasher"))
    }

    // MARK: - The manifest's equipment_types

    func testAManifestWithAndWithoutEquipmentTypes() throws {
        let without = try JSONDecoder().decode(VaultManifest.self, from: Self.fixture("manifest-without-equipment-types-v1.json"))
        XCTAssertNil(without.equipmentTypes)
        XCTAssertEqual(without.equipmentTypeList, [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try encoder.encode(without), as: UTF8.self).contains("equipment_types"),
                       "a manifest without the list encodes as it did")
        XCTAssertEqual(try Self.validatorIssues(without), [])

        let with = try JSONDecoder().decode(VaultManifest.self, from: Self.fixture("manifest-with-equipment-types-v1.json"))
        XCTAssertEqual(with.equipmentTypes, ["dryer", "dishwasher", "walk-in cooler"])
        XCTAssertEqual(try JSONDecoder().decode(VaultManifest.self, from: encoder.encode(with)), with)
        XCTAssertEqual(try Self.validatorIssues(with), [])
        // The licence core reads the list from the phone's own bytes.
        XCTAssertEqual(VaultPackRules.Manifest(json: try encoder.encode(with))?.equipmentTypes, with.equipmentTypes)
        // Kept through every rebuild of the manifest.
        XCTAssertEqual(with.markingDocumentsNotIncluded().equipmentTypes, with.equipmentTypes)
        XCTAssertEqual(with.withFiles(["other.md"]).equipmentTypes, with.equipmentTypes)
        XCTAssertEqual(with.withDocuments([], documentsDir: nil).equipmentTypes, with.equipmentTypes)
        XCTAssertEqual(VaultManualRemoval.reducedManifest(with, removing: "x.pdf").equipmentTypes, with.equipmentTypes)
    }

    func testABadEquipmentTypeListIsRefusedByName() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("manifest-without-equipment-types-v1.json")) as? [String: Any])
        let cases = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("manifest-equipment-types-negative-v1.json")) as? [[String: Any]])
        XCTAssertEqual(cases.count, 5)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            var manifest = base
            manifest["equipment_types"] = item["equipment_types"]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            let rules = try XCTUnwrap(VaultPackRules.Manifest(json: data))
            XCTAssertEqual(VaultPackRules.manifestIssues(rules), item["issues"] as? [String], name)
            if item["equipment_types"] is [String] {
                // The phone reads the list, and its validator refuses it in the same words.
                let phone = try JSONDecoder().decode(VaultManifest.self, from: data)
                XCTAssertEqual(try Self.validatorIssues(phone), item["issues"] as? [String], name)
            } else {
                XCTAssertThrowsError(try JSONDecoder().decode(VaultManifest.self, from: data), "\(name): the phone refuses it")
            }
        }
    }

    /// What the phone's own validator says about a vault with this manifest and its one core file.
    private static func validatorIssues(_ manifest: VaultManifest) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLearningRecollection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for file in manifest.files {
            try Data("# Core\n\nFixture content.\n".utf8).write(to: dir.appendingPathComponent(file))
        }
        return VaultValidator.validate(directory: dir).issues
    }

    func testACompanyLayerAddsEquipmentTypes() {
        XCTAssertNil(VaultLayerMerge.mergedEquipmentTypes(publisher: nil, company: nil))
        XCTAssertEqual(VaultLayerMerge.mergedEquipmentTypes(publisher: ["dryer"], company: nil), ["dryer"])
        XCTAssertEqual(VaultLayerMerge.mergedEquipmentTypes(publisher: ["dryer"], company: ["Dryer", "ice machine"]),
                       ["dryer", "ice machine"])
    }

    func testAVaultThatListsItsTypesHoldsBackASymptomOfAnotherType() {
        let entry = F.entry(subject: .symptom(equipmentType: "dishwasher", phrase: "Won't drain"), vaultIDs: [])
        let listing = LearningCorpus.VaultTarget(id: "listing", modelIndex: F.modelIndex(), equipmentTypes: ["dryer"])
        let open = LearningCorpus.VaultTarget(id: "open", modelIndex: F.modelIndex())
        let both = LearningCorpus.VaultTarget(id: "both", modelIndex: F.modelIndex(), equipmentTypes: ["Dishwasher"])
        let placement = LearningCorpus.placement(of: entry, among: [listing, open, both])
        XCTAssertEqual(placement.published, ["open", "both"])
        XCTAssertEqual(placement.unknownEquipmentType, ["listing"])
        XCTAssertEqual(placement.unknownModel, [])
    }

    // MARK: - Retrieval: the equipment type

    func testTheTurnsEquipmentTypeIsResolvedAsTheFixtureSays() throws {
        let data = try Self.fixture("equipment-type-turns-v1.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let vocabulary = try XCTUnwrap(object["vocabulary"] as? [String])
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let scope = VaultRetriever.EquipmentTypeScope(vocabulary: vocabulary,
                                                          activeTypes: item["activeTypes"] as? [String] ?? [])
            let resolved = scope.resolved(turn: item["turn"] as? String, jobContext: item["jobContext"] as? String)
            XCTAssertEqual(resolved, (item["resolved"] as? [String]).map(Set.init), name)
            for (type, admitted) in try XCTUnwrap(item["admits"] as? [String: Bool]) {
                XCTAssertEqual(VaultRetriever.EquipmentTypeScope.admits(type, resolved: resolved), admitted, "\(name): \(type)")
            }
            XCTAssertTrue(VaultRetriever.EquipmentTypeScope.admits(nil, resolved: resolved), "\(name): not a symptom learning")
        }
    }

    private func raw(_ id: String, sim: Float, source: RetrievalSource = .teamLearning, type: String? = nil,
                     recalled: Bool = false, name: String? = nil) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: id, documentName: name ?? id, chunkIndex: 0, text: "Finding: \(id)",
                              similarity: sim, page: nil, section: nil, source: source,
                              subjectEquipmentType: type, isUnconfirmedRecollection: recalled)
    }

    private func retriever(_ passages: [DocumentStore.Passage], vocabulary: [String] = ["dryer", "dishwasher"],
                           active: [String] = []) -> VaultRetriever {
        var retriever = VaultRetriever(query: { _, _ in passages }, policy: RetrievalEvidencePolicy(similarityFloor: 0.3))
        retriever.equipmentTypes = VaultRetriever.EquipmentTypeScope(vocabulary: vocabulary, activeTypes: active)
        return retriever
    }

    func testADryerSymptomIsNeverRetrievedForADishwasherTurn() {
        let passages = [raw("dryer-symptom", sim: 0.95, type: "dryer"),
                        raw("dishwasher-symptom", sim: 0.6, type: "Dishwasher"),
                        raw("model-learning", sim: 0.5)]
        let dishwasher = retriever(passages).retrieve(.init(turn: "the dishwasher won't drain", limit: 4))
        XCTAssertTrue(dishwasher.isTeamLearningOnly)
        XCTAssertEqual(dishwasher.passages.map(\.documentId), ["dishwasher-symptom", "model-learning"],
                       "a dryer symptom never answers a dishwasher turn; a model learning is not scoped by type")
        let dryer = retriever(passages).retrieve(.init(turn: "the dryer won't heat", limit: 4))
        XCTAssertEqual(dryer.passages.map(\.documentId), ["dryer-symptom", "model-learning"])
        // By the unit's own type when the turn names none.
        let unit = retriever(passages, active: ["dryer"]).retrieve(.init(turn: "it won't start", limit: 4))
        XCTAssertEqual(unit.passages.map(\.documentId), ["dryer-symptom", "model-learning"])
        // Nothing resolves a type: nothing drops a symptom learning, but it ranks below the model
        // learning (owner decision 2026-11-27).
        let unscoped = retriever(passages).retrieve(.init(turn: "it won't start", limit: 4))
        XCTAssertEqual(unscoped.passages.map(\.documentId), ["model-learning", "dryer-symptom", "dishwasher-symptom"])
        // A retriever without a scope is unchanged.
        let none = VaultRetriever(query: { _, _ in passages }, policy: RetrievalEvidencePolicy(similarityFloor: 0.3))
            .retrieve(.init(turn: "the dishwasher won't drain", limit: 4))
        XCTAssertEqual(none.passages.count, 3)
    }

    func testThroughTheFactoryTheUnitsTypeBoundsSymptomLearnings() async throws {
        let root = F.tempDirectory("TeamLearningRecollection")
        defer { try? FileManager.default.removeItem(at: root) }
        let previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        let previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        let previousEntitlement = EntitlementTestScope.grant(tier: .team)
        defer {
            VaultImporter.uninstall(id: F.vaultId)
            VaultRegistry.shared.reloadUserManifests()
            VaultRegistry.shared.resetCache()
            if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
            Config.hipaaMode = previousHipaa
            EntitlementTestScope.restore(previousEntitlement)
        }
        VaultRegistry.shared.resetCache()
        let store = F.documentStore(in: root)
        let entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        let manifest = try VaultImporter.install(from: F.writeVault(in: root))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)
        let sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        sessions.documentStore = store
        sessions.learningEntries = entries
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        _ = try sessions.startSession(vaultId: F.vaultId, assetId: nil)

        let targets = [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex())]
        func publish(_ entry: LearningEntry) -> String {
            entries.upsert(entry)
            LearningCorpus.publish(entry, vaults: targets, store: store)
            return LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId)
        }
        // The crew says what the unit is; then one symptom of its type and one of another's.
        _ = publish(F.entry(subject: .model(modelToken: F.model090, equipmentType: "Rooftop unit"),
                            finding: "The inducer hums before the igniter glows"))
        let same = publish(LearningEntry(subject: .symptom(equipmentType: "rooftop unit", phrase: "Igniter glows late"),
                                         vaultIDs: [F.vaultId], finding: "The igniter glows late when the inducer hums",
                                         approvedAt: Self.now, approvedByRole: "Owner", approvedByName: "Owner",
                                         origin: .recollection))
        let other = publish(LearningEntry(subject: .symptom(equipmentType: "walk-in cooler", phrase: "Igniter glows late"),
                                          vaultIDs: [F.vaultId], finding: "The igniter glows late when the inducer hums",
                                          approvedAt: Self.now, approvedByRole: "Owner", approvedByName: "Owner",
                                          origin: .recollection))
        func retrieved() -> [VaultRetriever.Passage] {
            sessions.makeRetriever(store: sessions.activeVault!, documentStore: store)
                .retrieve(.init(turn: "the igniter glows late when the inducer hums", limit: 10)).passages
        }
        XCTAssertTrue(retrieved().contains { $0.documentId == other }, "with no unit, nothing scopes a symptom learning")
        let model = try XCTUnwrap(sessions.modelIndex.models.first { $0.tokens.contains(F.model090) })
        sessions.setEquipment(EquipmentIdentity(model: model, token: F.model090, source: .spoken))
        let scoped = retrieved()
        XCTAssertTrue(scoped.contains { $0.documentId == same }, "\(scoped.map(\.documentId))")
        XCTAssertFalse(scoped.contains { $0.documentId == other }, "a walk-in cooler's symptom never answers on a rooftop unit")
        XCTAssertEqual(scoped.first { $0.documentId == same }?.isUnconfirmedRecollection, true,
                       "the factory marks a recollection no job has confirmed")
    }

    func testTheUnitsTypesComeFromItsLiveModelEntries() {
        let active: Set<String> = [F.model090.uppercased(), "090XV60C"]
        var retracted = F.entry(subject: .model(modelToken: F.model090, equipmentType: "ice machine"))
        retracted.retractedAt = Self.now
        let entries = [F.entry(subject: .model(modelToken: " slp99uh090xv60ck ", equipmentType: "Rooftop unit")),
                       F.entry(subject: .model(modelToken: F.model090, equipmentType: "rooftop  UNIT")),
                       F.entry(subject: .model(modelToken: F.model070, equipmentType: "dryer")),
                       retracted]
        let scope = FieldSessionService.equipmentTypeScope(vocabulary: [], activeTokens: active, entries: entries)
        XCTAssertEqual(scope?.activeTypes, ["Rooftop unit"])
        XCTAssertNil(FieldSessionService.equipmentTypeScope(vocabulary: [], activeTokens: [], entries: entries),
                     "no list and no unit: nothing is scoped")
        XCTAssertEqual(FieldSessionService.equipmentTypeScope(vocabulary: ["dryer"], activeTokens: [], entries: entries)?.vocabulary,
                       ["dryer"])
    }

    // MARK: - Ranking and the lead-in

    func testAJobConfirmedLearningRanksAheadOfARecollection() {
        let passages = [raw("manual", sim: 0.97, source: .manual),
                        raw("recalled", sim: 0.95, recalled: true),
                        raw("confirmed", sim: 0.6),
                        raw("below-floor", sim: 0.1)]
        let outcome = retriever(passages, vocabulary: []).retrieve(.init(turn: "door sweats", limit: 4))
        XCTAssertEqual(outcome.passages.map(\.documentId), ["manual", "confirmed", "recalled"],
                       "the manual keeps its place; the job-confirmed learning leads the learnings")
        // With room for one learning beside the manual page, it is the job-confirmed one.
        let one = retriever(passages, vocabulary: []).retrieve(.init(turn: "door sweats", limit: 2))
        XCTAssertEqual(one.passages.map(\.documentId), ["manual", "confirmed"])
        // A recollection that alone clears the floor still answers.
        let alone = retriever([raw("recalled", sim: 0.95, recalled: true), raw("weak", sim: 0.1)], vocabulary: [])
            .retrieve(.init(turn: "door sweats", limit: 4))
        XCTAssertEqual(alone.passages.map(\.documentId), ["recalled"])
    }

    func testTheOrderMovesOnlyLearningsAndKeepsEachGroupsOrder() {
        func p(_ id: String, _ source: RetrievalSource, recalled: Bool = false) -> VaultRetriever.Passage {
            var passage = VaultRetriever.Passage(documentId: id, documentName: id, chunkIndex: 0, text: id, page: nil,
                                                 section: nil, similarity: 0.5, score: 0.5, matchedTokens: [], source: source)
            passage.isUnconfirmedRecollection = recalled
            return passage
        }
        let ranked = [p("r1", .teamLearning, recalled: true), p("m1", .manual), p("r2", .teamLearning, recalled: true),
                      p("s1", .teamLearning), p("m2", .capturedManual), p("s2", .teamLearning)]
        XCTAssertEqual(VaultRetriever.learningsBySeenOnAJob(ranked).map(\.documentId), ["s1", "m1", "s2", "r1", "m2", "r2"])
        XCTAssertEqual(VaultRetriever.learningsBySeenOnAJob([]), [])
    }

    /// Owner decision 2026-11-27: with no equipment type resolved, a symptom learning ranks below
    /// the model learnings, inside the existing order (job-confirmed ahead of recollections), and
    /// never above a manual passage.
    func testWithNoTypeResolvedSymptomLearningsRankBelowModelLearnings() {
        let passages = [raw("manual", sim: 0.97, source: .manual),
                        raw("confirmed-symptom", sim: 0.96, type: "dryer"),
                        raw("recalled-symptom", sim: 0.95, type: "dryer", recalled: true),
                        raw("recalled-model", sim: 0.7, recalled: true),
                        raw("confirmed-model", sim: 0.6),
                        raw("below-floor-model", sim: 0.1)]
        let outcome = retriever(passages).retrieve(.init(turn: "it won't start", limit: 6))
        XCTAssertEqual(outcome.passages.map(\.documentId),
                       ["manual", "confirmed-model", "confirmed-symptom", "recalled-model", "recalled-symptom"])
        XCTAssertEqual(outcome.passages.filter(\.isUnscopedSymptom).map(\.documentId),
                       ["confirmed-symptom", "recalled-symptom"])
        // With room for one learning beside the manual page, it is the model learning.
        let one = retriever(passages).retrieve(.init(turn: "it won't start", limit: 2))
        XCTAssertEqual(one.passages.map(\.documentId), ["manual", "confirmed-model"])
        // A retriever with no scope at all resolves no type either: the same order.
        let noScope = VaultRetriever(query: { _, _ in passages }, policy: RetrievalEvidencePolicy(similarityFloor: 0.3))
            .retrieve(.init(turn: "it won't start", limit: 6))
        XCTAssertEqual(noScope.passages.map(\.documentId), outcome.passages.map(\.documentId))
        // An unscoped symptom learning that alone clears the floor still answers.
        let alone = retriever([raw("recalled-symptom", sim: 0.95, type: "dryer", recalled: true),
                               raw("weak", sim: 0.1)]).retrieve(.init(turn: "it won't start", limit: 4))
        XCTAssertEqual(alone.passages.map(\.documentId), ["recalled-symptom"])
        XCTAssertTrue(alone.isTeamLearningOnly)
    }

    /// When a type resolves, nothing changes: the turn's type ranks as any learning does, another
    /// type's is dropped.
    func testWhenATypeResolvesSymptomLearningsRankAsBefore() {
        let passages = [raw("dryer-symptom", sim: 0.95, type: "dryer"),
                        raw("dishwasher-symptom", sim: 0.9, type: "dishwasher"),
                        raw("model-learning", sim: 0.6)]
        let named = retriever(passages).retrieve(.init(turn: "the dryer won't heat", limit: 4))
        XCTAssertEqual(named.passages.map(\.documentId), ["dryer-symptom", "model-learning"])
        XCTAssertFalse(named.passages.contains(where: \.isUnscopedSymptom))
        let unit = retriever(passages, active: ["dryer"]).retrieve(.init(turn: "it won't start", limit: 4))
        XCTAssertEqual(unit.passages.map(\.documentId), ["dryer-symptom", "model-learning"])
    }

    /// The pure order: four groups, each keeping its own order, and manual slots untouched.
    func testTheOrderPutsUnscopedSymptomsLastWithinEachGroup() {
        func p(_ id: String, _ source: RetrievalSource, recalled: Bool = false, symptom: Bool = false) -> VaultRetriever.Passage {
            var passage = VaultRetriever.Passage(documentId: id, documentName: id, chunkIndex: 0, text: id, page: nil,
                                                 section: nil, similarity: 0.5, score: 0.5, matchedTokens: [], source: source)
            passage.isUnconfirmedRecollection = recalled
            passage.isUnscopedSymptom = symptom
            return passage
        }
        let ranked = [p("rs1", .teamLearning, recalled: true, symptom: true), p("m1", .manual),
                      p("cs1", .teamLearning, symptom: true), p("r1", .teamLearning, recalled: true),
                      p("c1", .teamLearning), p("m2", .capturedManual), p("cs2", .teamLearning, symptom: true),
                      p("c2", .teamLearning)]
        XCTAssertEqual(VaultRetriever.learningsBySeenOnAJob(ranked).map(\.documentId),
                       ["c1", "m1", "c2", "cs1", "cs2", "m2", "r1", "rs1"])
    }

    func testARecollectionOnlyAnswerOpensWithTheRecalledLeadIn() {
        func entry(_ id: String, crew: Bool, count: Int?) -> TeamLearningDisclosure.Entry {
            TeamLearningDisclosure.Entry(entryID: id, approvedByRole: "Owner", citation: id, confirmedJobCount: count,
                                         contradictsSafetyNote: false, isCrewExperience: crew)
        }
        let recalled = TeamLearningDisclosure(restsOnLearningAlone: true,
                                              entries: [entry("a", crew: true, count: nil), entry("b", crew: true, count: nil)])
        XCTAssertEqual(recalled.leadIn, TeamLearningDisclosure.crewExperienceLeadIn)
        XCTAssertEqual(recalled.leadIn, "From your company's experience (not the manufacturer's manual):")
        XCTAssertEqual(TeamLearningDisclosure.prepend(recalled.leadIn!, to: "Replace the heater fuse."),
                       "From your company's experience (not the manufacturer's manual): Replace the heater fuse.")
        // A learning seen on jobs among them: FP's lead-in, with its count, whichever came first.
        let mixed = TeamLearningDisclosure(restsOnLearningAlone: true,
                                           entries: [entry("a", crew: true, count: nil), entry("b", crew: false, count: 3)])
        XCTAssertEqual(mixed.leadIn, "The manual doesn't cover this. Your crew's own finding, noted on 3 previous jobs:")
        XCTAssertNil(TeamLearningDisclosure(restsOnLearningAlone: false, entries: [entry("a", crew: true, count: nil)]).leadIn)
    }
}
