import Foundation
import XCTest
@testable import OpenGlasses

/// Plan IM P4 — what's missing, and site recordings.
///
/// The vault is HV's fictional dual-fuel fixture (`Fixtures/SiteSystemVault`: NV80F060, NV36HP2,
/// NV48HP2). Every model, serial, site and word here is invented.
@MainActor
final class ExperienceCoverageTests: XCTestCase {

    private static let approved = Date(timeIntervalSince1970: 1_795_600_000)

    private func vault(id: String = SiteSystemFixtures.vaultId, equipmentTypes: [String]? = nil) throws -> LearningCorpus.VaultTarget {
        LearningCorpus.VaultTarget(id: id, modelIndex: try SiteSystemFixtures.modelIndex(), equipmentTypes: equipmentTypes)
    }

    private func entry(_ subject: LearningEntry.Subject, vaults: [String] = [], origin: LearningCandidate.Origin = .recollection,
                       confirmed: Int? = nil, retracted: Bool = false) -> LearningEntry {
        var entry = LearningEntry(subject: subject, vaultIDs: vaults, finding: "Reseat the board connector.",
                                  approvedAt: Self.approved, approvedByRole: "Service lead", approvedByName: "",
                                  origin: origin, confirmedJobCount: confirmed)
        if retracted { entry.retractedAt = Self.approved }
        return entry
    }

    func testWithNoExperienceEveryModelIsMissingInTheIndexOrder() throws {
        let coverage = ExperienceCoverage.of(try vault(), entries: [])
        XCTAssertEqual(coverage.vaultId, SiteSystemFixtures.vaultId)
        XCTAssertEqual(coverage.vaultName, "Fictional Dual-Fuel Example")
        XCTAssertEqual(coverage.totalCount, 3)
        XCTAssertEqual(coverage.missingNames, ["NV80F060", "NV36HP2", "NV48HP2"])
        XCTAssertEqual(ExperienceCoverageCopy.summary(coverage), "3 models in your vault have no crew experience yet.")
    }

    func testAModelIsCoveredByIdentityWhateverTheOriginOrSource() throws {
        let entries = [
            // A recollection, spelled as the heading's alternative, in another case.
            entry(.model(modelToken: "nv36-hp2")),
            // A learning seen on a job, scoped to this vault.
            entry(.model(modelToken: "NV80F060", equipmentType: "Furnace"), vaults: [SiteSystemFixtures.vaultId],
                  origin: .spoken, confirmed: 3),
        ]
        let coverage = ExperienceCoverage.of(try vault(), entries: entries)
        XCTAssertEqual(coverage.missingNames, ["NV48HP2"])
        XCTAssertEqual(coverage.coveredCount, 2)
        XCTAssertEqual(ExperienceCoverageCopy.summary(coverage), "1 model in your vault has no crew experience yet.")

        let all = entries + [entry(.model(modelToken: "NV48HP2"))]
        let full = ExperienceCoverage.of(try vault(), entries: all)
        XCTAssertTrue(full.missing.isEmpty)
        XCTAssertEqual(ExperienceCoverageCopy.summary(full), "Every model in your vault has crew experience.")
        XCTAssertNil(full.request(askedAt: Self.approved), "nothing to ask for")
    }

    func testOnlyEntriesThatWouldAnswerInThisVaultCount() throws {
        let entries = [
            entry(.model(modelToken: "NV36HP2"), retracted: true),
            entry(.model(modelToken: "NV48HP2"), vaults: ["another-vault"]),
            // Prose is never read: the finding naming a model covers nothing.
            LearningEntry(subject: .practice(topic: "Board connectors"), vaultIDs: [],
                          finding: "On the NV80F060 reseat the connector.", approvedAt: Self.approved,
                          approvedByRole: "Service lead", approvedByName: ""),
            // A token this vault does not know is held back from it, so it covers nothing here.
            entry(.model(modelToken: "NV80F06")),
        ]
        XCTAssertEqual(ExperienceCoverage.of(try vault(), entries: entries).missingCount, 3)
    }

    func testASymptomEntryCoversNoModel() throws {
        // Admitted in the vault (its type is listed), and still about no model: retrieval scopes it
        // by the unit's type, which only the unit's own model entries give.
        let symptom = entry(.symptom(equipmentType: "Heat pump", phrase: "short cycles in the cold"))
        let target = try vault(equipmentTypes: ["Heat pump", "Furnace"])
        XCTAssertEqual(LearningCorpus.placement(of: symptom, among: [target]).published, [target.id])
        XCTAssertEqual(ExperienceCoverage.of(target, entries: [symptom]).missingCount, 3)
    }

    func testTheWordingForNoneOneAndMany() {
        XCTAssertNil(ExperienceCoverageCopy.summary(missing: 0, total: 0), "a vault with no models has nothing to count")
        XCTAssertEqual(ExperienceCoverageCopy.summary(missing: 0, total: 5), "Every model in your vault has crew experience.")
        XCTAssertEqual(ExperienceCoverageCopy.summary(missing: 1, total: 5), "1 model in your vault has no crew experience yet.")
        XCTAssertEqual(ExperienceCoverageCopy.summary(missing: 14, total: 20), "14 models in your vault have no crew experience yet.")
        XCTAssertEqual(ExperienceCoverageCopy.requestLine, "Could you record what you know about these?")
    }

    func testTheListToSendNamesModelsAVaultAndADayAndNobody() throws {
        let coverage = ExperienceCoverage.of(try vault(), entries: [entry(.model(modelToken: "NV36HP2"))])
        let request = try XCTUnwrap(coverage.request(askedAt: Date(timeIntervalSince1970: 1_795_600_000.7)))
        XCTAssertEqual(request.models, ["NV80F060", "NV48HP2"])
        XCTAssertEqual(request.vaultName, "Fictional Dual-Fuel Example")
        XCTAssertEqual(request.askedAt, Date(timeIntervalSince1970: 1_795_600_000), "whole seconds")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["vault_id", "vault_name", "models", "asked_at"], "nobody is assigned")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ExperienceCoverageRequest.self, from: data), request)

        let header = ExperienceCoverageCopy.requestHeader(request, locale: Locale(identifier: "en_GB"),
                                                          timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(header.hasPrefix("Fictional Dual-Fuel Example · asked "), header)
    }

    func testShownOnlyOnAReviewersDeviceWhereTheRecorderIsOffered() {
        XCTAssertTrue(ExperienceCoverage.isShown(reviewerDevice: true, recorder: .available))
        XCTAssertTrue(ExperienceCoverage.isShown(reviewerDevice: true, recorder: .unavailable("Lapsed.")))
        XCTAssertFalse(ExperienceCoverage.isShown(reviewerDevice: false, recorder: .available))
        // Medical Compliance, Field Assist off, or no team learnings on the licence.
        XCTAssertFalse(ExperienceCoverage.isShown(reviewerDevice: true, recorder: .notOffered))
    }

    func testNoPlanLetterOrBetaInWhatItSays() {
        let lines = [ExperienceCoverageCopy.sectionTitle, ExperienceCoverageCopy.missingListTitle,
                     ExperienceCoverageCopy.requestLine, ExperienceRecorderCopy.siteTitle,
                     ExperienceRecorderCopy.carPlaySitePrompts] + ExperienceRecorderCopy.sitePrompts
            + [1, 2].compactMap { ExperienceCoverageCopy.summary(missing: $0, total: 3) }
        for line in lines {
            XCTAssertNil(line.range(of: #"\bPlan [A-Z]{1,2}\b|\(beta\)|\bIM\b|\bHV\b"#, options: .regularExpression), line)
        }
    }
}

// MARK: - The recording's kind

@MainActor
final class ExperienceRecordingKindTests: XCTestCase {

    func testARecordingKeptBeforeKindsDecodesAsAnExperienceAndEncodesAsItWas() throws {
        let old = """
        {"audio_deleted_at":null,"created_at":"2026-11-20T09:00:00Z","duration":75,"id":"0123456789abcdef0123456789abcdef",\
        "redactions":[],"status":"recorded","transcript":"The board throws E7 after rain","vault_id":"fixture"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(ExperienceRecording.self, from: Data(old.utf8))
        XCTAssertEqual(recording.kind, .experience)
        XCTAssertEqual(recording.transcript, "The board throws E7 after rain")
        XCTAssertEqual(recording.status, .recorded)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(recording)) as? NSDictionary)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(old.utf8), options: .mutableContainers) as? NSMutableDictionary)
        original.removeObject(forKey: "audio_deleted_at")
        XCTAssertEqual(again, original, "an experience recording's bytes carry no kind")
    }

    func testASiteRecordingKeepsItsKindThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SiteKind-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExperienceRecordingStore(directory: root)
        let site = ExperienceRecording(kind: .site, createdAt: Date(), duration: 40, transcript: "The plant room",
                                       redactions: [], vaultId: "fixture")
        store.add(site)
        XCTAssertTrue(store.advance(id: site.id, to: .sent))
        let reopened = ExperienceRecordingStore(directory: root)
        XCTAssertEqual(reopened.recording(id: site.id)?.kind, .site)
        XCTAssertEqual(reopened.recording(id: site.id)?.status, .sent)
    }
}

// MARK: - The recorder, recording a site

@MainActor
private final class SiteScriptedCapture: ExperienceCapture {
    private(set) var url: URL?
    func prepare() async -> String? { nil }
    func start(writingTo url: URL, onStretch: @escaping @MainActor (String) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 4096))
    }
    func stop() async -> ExperienceCaptureEnding { ExperienceCaptureEnding(audioWritten: true, lastStretch: nil) }
}

@MainActor
final class ExperienceRecorderSiteTests: XCTestCase {

    private var root: URL!
    private var store: ExperienceRecordingStore!
    private var spoken: [String] = []
    private var filed: [String] = []
    private var openJob: String?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SiteRecorder-\(UUID().uuidString)")
        store = ExperienceRecordingStore(directory: root.appendingPathComponent("store", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func recorder() -> ExperienceRecorder {
        ExperienceRecorder(store: store, seams: .init(
            availability: { .available },
            conversationActive: { false },
            speak: { [unowned self] line in self.spoken.append(line) },
            makeCapture: { SiteScriptedCapture() },
            captureFolder: { [unowned self] in self.root.appendingPathComponent("capture", isDirectory: true) },
            openJob: { [unowned self] in self.openJob },
            fileOnJob: { [unowned self] transcript in
                self.filed.append(transcript)
                return .filed(count: 1, jobReference: "1005")
            },
            vaultInForce: { "fixture" },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            startTicker: { _ in {} }))
    }

    func testASiteRecordingDuringAnOpenJobIsKeptAndNeverFiledAsALearning() async throws {
        openJob = "session-1"
        let recorder = recorder()
        await recorder.start(from: .carPlay, kind: .site)
        XCTAssertTrue(spoken[0].contains(ExperienceRecorderCopy.carPlaySitePrompts))
        XCTAssertFalse(spoken[0].contains(ExperienceRecorderCopy.carPlayPrompts))
        await recorder.heard("The furnace in the basement feeds the heat pump. That's all.")
        XCTAssertTrue(filed.isEmpty, "a site recording never becomes a candidate")
        let kept = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(kept.kind, .site)
        XCTAssertEqual(recorder.lastOutcome, .kept(recordingId: kept.id))

        // The next session is a case again unless it says otherwise, and files on the job.
        await recorder.start(from: .phone)
        await recorder.heard("The board needed reseating. That's all.")
        XCTAssertEqual(filed, ["The board needed reseating"])
    }
}

// MARK: - Drafting a site document

@MainActor
final class SiteRecordingDraftTests: XCTestCase {

    private final class StubModel: RecollectionDraftModel {
        var answers: [Data?]
        var requests: [String] = []
        var schemas: [[String: Any]] = []
        init(_ answers: [Data?]) { self.answers = answers }
        func extract(system: String, transcript: String, schema: [String: Any]) async -> Data? {
            requests.append(transcript)
            schemas.append(schema)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    nonisolated private static let transcript = "This is the Hillside house system. In the basement there's the NV80-F060 furnace, "
        + "serial NV80-2201. The side yard heat pump is an NV36 HP2. The hall thermostat is an AT-9. "
        + "The thermostat talks to the furnace over a 4-wire serial bus. The heat pump shows E77 when the furnace "
        + "board drops off the bus, so check the bus at the furnace first. That's all."

    nonisolated private static func recording(_ transcript: String = transcript,
                                              kind: ExperienceRecording.Kind = .site) -> ExperienceRecording {
        ExperienceRecording(id: "0123456789abcdef0123456789abcdef", kind: kind,
                            createdAt: Date(timeIntervalSince1970: 1_795_600_000), duration: 48,
                            transcript: transcript, redactions: [], vaultId: SiteSystemFixtures.vaultId)
    }

    /// The model's answer, as the schema asks for it: every member, empty where nothing was said.
    private static func answer(_ change: (inout [String: Any]) -> Void = { _ in }) -> [String: Any] {
        var answer: [String: Any] = [
            "name": "Hillside house system", "location_label": "Hillside house", "notes": "",
            "units": [
                ["id": "furnace", "model": "NV80F060", "serial": "NV80-2201", "label": "basement furnace", "covered": true],
                ["id": "heatpump", "model": "NV36HP2", "serial": "", "label": "side yard heat pump", "covered": true],
                ["id": "tstat", "model": "AT-9", "serial": "", "label": "hall thermostat", "covered": false],
            ],
            "connections": [
                ["from": "tstat", "to": "furnace", "kind": "communication", "medium": "", "protocol": "4-wire serial bus",
                 "direction": "", "detail": ""],
            ],
            "controls": [], "integrations": [], "settings": [],
            "interaction_faults": [
                ["seen_on": "heatpump", "code": "E77", "link": "furnace",
                 "text": "Shows E77 when the furnace board drops off the bus; check the bus at the furnace first."],
            ],
        ]
        change(&answer)
        return answer
    }

    private static func data(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

    private static func changingUnit(_ index: Int, _ change: @escaping (inout [String: Any]) -> Void) -> [String: Any] {
        answer { answer in
            var units = answer["units"] as! [[String: Any]]
            change(&units[index])
            answer["units"] = units
        }
    }

    private func drafter(_ model: StubModel, reviewer: Bool = true, hipaa: Bool = false) -> SiteRecordingDrafter {
        let drafter = SiteRecordingDrafter(model: model)
        drafter.context = { .init(isReviewerDevice: reviewer, medicalComplianceMode: hipaa) }
        return drafter
    }

    private func draft(_ answer: [String: Any], recording: ExperienceRecording = recording(),
                       reviewer: Bool = true, hipaa: Bool = false) async throws
        -> (Result<SiteRecordingDraft, SiteRecordingDraftValidator.Refusal>, StubModel) {
        let model = StubModel([try Self.data(answer)])
        let result = await drafter(model, reviewer: reviewer, hipaa: hipaa)
            .draft(recording, index: try SiteSystemFixtures.modelIndex())
        return (result, model)
    }

    private func refusal(_ answer: [String: Any]) async throws -> SiteRecordingDraftValidator.Refusal? {
        let (result, _) = try await draft(answer)
        if case .failure(let refusal) = result { return refusal }
        XCTFail("drafted")
        return nil
    }

    // MARK: Drafted

    func testASiteRecordingDraftsASiteDocumentThatHVsValidatorAccepts() async throws {
        let (result, model) = try await draft(Self.answer())
        let draft = try result.get()
        XCTAssertEqual(draft.path, "sites/site-0123456789abcdef0123456789abcdef.json")
        XCTAssertEqual(draft.document.id, "site-0123456789abcdef0123456789abcdef")
        XCTAssertEqual(draft.document.format, SiteSystemDocument.format)
        XCTAssertEqual(draft.document.units.map(\.model), ["NV80F060", "NV36HP2", "AT-9"])
        XCTAssertEqual(draft.document.units.map(\.isCovered), [true, true, false])
        XCTAssertEqual(draft.document.units[1].serial, nil, "an empty text is not said, so it is left out")
        XCTAssertNil(draft.document.controls, "an empty list is left out")
        XCTAssertNil(draft.document.externalLocationIDs)
        XCTAssertEqual(draft.document.interactionFaults?.first?.link, "furnace")

        // The bytes are a site file the vault would install as they are.
        let checked = SiteSystemValidator.check(draft.data, path: draft.path, modelCovered: try SiteSystemFixtures.covered())
        XCTAssertEqual(checked.issues, [])
        XCTAssertEqual(checked.document, draft.document)

        // One call, told the vault's models and only the words before "that's all".
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertTrue(model.requests[0].contains("Models this vault has sections for: NV80F060; NV36HP2; NV48HP2."))
        XCTAssertTrue(model.requests[0].contains("check the bus at the furnace first."))
        XCTAssertFalse(model.requests[0].contains("That's all"))
        XCTAssertEqual(draft.segment.start, 0)
    }

    func testTheSchemaIsClosedAndAsksForEveryMember() async throws {
        let schema = SiteRecordingDraftRules.jsonSchema
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), Set(properties.keys))
        XCTAssertEqual(Set(properties.keys), ["name", "location_label", "notes", "units", "connections", "controls",
                                              "integrations", "settings", "interaction_faults"])
        for stamped in SiteRecordingDraftRules.stampedMembers { XCTAssertNil(properties[stamped], stamped) }
        let units = try XCTUnwrap(properties["units"] as? [String: Any])
        let unit = try XCTUnwrap(units["items"] as? [String: Any])
        XCTAssertEqual(unit["additionalProperties"] as? Bool, false)
        XCTAssertNil((unit["properties"] as? [String: Any])?["external_ids"])
        // Every member HV knows of, less the stamped ones, is one the schema asks for.
        XCTAssertEqual(Set(properties.keys).union(SiteRecordingDraftRules.stampedMembers), SiteSystemValidator.documentMembers)
    }

    // MARK: Refused, by name

    func testAnUnknownModelIsRefusedByHVsRule() async throws {
        let answer = Self.changingUnit(1) { $0["model"] = "NV99HP9" }
        guard case .siteDocument(let issues) = try await refusal(answer) else { return XCTFail("not HV's refusal") }
        XCTAssertTrue(issues.contains { $0.contains("is not a model this vault has a section for") }, "\(issues)")
    }

    func testAUnitNamingAnotherVaultIsRefused() async throws {
        let answer = Self.changingUnit(0) { $0["vault_id"] = "another-vault" }
        guard case .siteDocument(let issues) = try await refusal(answer) else { return XCTFail("not HV's refusal") }
        XCTAssertTrue(issues.contains { $0.contains("names another vault") }, "\(issues)")
    }

    func testTheMembersThePhoneStampsAreNeverTakenFromTheModel() async throws {
        var refused = try await refusal(Self.answer { $0["id"] = "hillside-house" })
        XCTAssertEqual(refused, .stampedMember("id"))
        refused = try await refusal(Self.answer { $0["external_location_ids"] = [["system": "example-fsm", "id": "loc-1"]] })
        XCTAssertEqual(refused, .stampedMember("external_location_ids"))
        refused = try await refusal(Self.changingUnit(0) { $0["external_ids"] = [["system": "example-fsm", "id": "a-1"]] })
        XCTAssertEqual(refused, .stampedMember("units[0].external_ids"))
    }

    func testAModelOrSerialNobodySaidIsRefused() async throws {
        var refused = try await refusal(Self.changingUnit(0) { $0["serial"] = "NV80-2209" })
        XCTAssertEqual(refused, .notSaid("units[0].serial"))
        // On the vault's list, so HV accepts it, but nobody said it.
        refused = try await refusal(Self.changingUnit(1) { $0["model"] = "NV48HP2" })
        XCTAssertEqual(refused, .notSaid("units[1].model"))
    }

    func testWordsNobodySaidAreRefusedNotKept() async throws {
        var refused = try await refusal(Self.changingUnit(0) { $0["label"] = "basement gas furnace" })
        XCTAssertEqual(refused, .unsupported("units[0].label"))
        refused = try await refusal(Self.answer { $0["notes"] = "Installed in 2024." })
        XCTAssertEqual(refused, .unsupported("notes"))
    }

    func testAMissingRequiredMemberIsHVsRefusalNotAFillIn() async throws {
        let refused = try await refusal(Self.answer { $0["name"] = "" })
        guard case .siteDocument(let issues) = refused else { return XCTFail("\(String(describing: refused))") }
        XCTAssertTrue(issues.contains { $0.hasSuffix("name is missing") }, "\(issues)")
    }

    func testNoAnswerOrNotAnObjectDraftsNothing() async throws {
        let index = try SiteSystemFixtures.modelIndex()
        var result = await drafter(StubModel([nil])).draft(Self.recording(), index: index)
        XCTAssertEqual(result.failure, .noAnswer)
        result = await drafter(StubModel([try Self.data([Self.answer()])])).draft(Self.recording(), index: index)
        XCTAssertEqual(result.failure, .malformed)
    }

    // MARK: Gates

    func testTheGatesAreThoseOfTheRecollectionPass() async throws {
        var (result, model) = try await draft(Self.answer(), reviewer: false)
        XCTAssertEqual(result.failure, .notReviewerDevice)
        XCTAssertTrue(model.requests.isEmpty, "nothing reaches a model")
        (result, model) = try await draft(Self.answer(), hipaa: true)
        XCTAssertEqual(result.failure, .medicalCompliance)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(SiteRecordingDraftValidator.Refusal.notReviewerDevice.message,
                       RecollectionDrafter.Refusal.notReviewerDevice.message)
    }

    func testAnEmptyTranscriptDraftsNothing() async throws {
        for words in [" … ", "That's all."] {
            let (result, model) = try await draft(Self.answer(), recording: Self.recording(words))
            XCTAssertEqual(result.failure, .emptyTranscript, words)
            XCTAssertTrue(model.requests.isEmpty)
        }
    }

    func testEachKindDraftsOnlyItsOwnThing() async throws {
        let (result, model) = try await draft(Self.answer(), recording: Self.recording(kind: .experience))
        XCTAssertEqual(result.failure, .notASiteRecording)
        XCTAssertTrue(model.requests.isEmpty)

        // And a site recording never drafts a learning candidate.
        let recollections = RecollectionDrafter(model: StubModel([]))
        recollections.context = { .init(isReviewerDevice: true, medicalComplianceMode: false) }
        let vault = RecollectionDraftValidator.Vault(index: try SiteSystemFixtures.modelIndex(), equipmentTypes: [])
        switch await recollections.draft(Self.recording(), vault: vault) {
        case .failure(let refusal): XCTAssertEqual(refusal, .siteRecording)
        case .success: XCTFail("a site recording drafted learnings")
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
