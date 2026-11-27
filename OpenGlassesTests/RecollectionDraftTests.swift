import Foundation
import XCTest
@testable import OpenGlasses

/// Plan IM P2 — the drafting pass: the segmenter, one schema-forced extraction per segment against
/// a stub model, and the validator. The golden fixtures are
/// `Contracts/fixtures/team-learning-v1/recollection-draft-schema-v1.json` and
/// `recollection-drafts-v1.json` (ten scripted recollections and the answers the rules refuse), which
/// `Contracts/tests/test_recollection_drafts.py` checks too. Every unit, place and word is invented.
@MainActor
final class RecollectionDraftTests: XCTestCase {

    // MARK: - Fixtures

    private struct Case {
        let name: String
        let recording: ExperienceRecording
        let segments: [RecollectionDraft.Span]
        let answers: [Data]
        let drafts: [RecollectionDraft]
        let siteNotes: [RecollectionSiteNote]
    }

    private struct RefusalCase {
        let name: String
        let caseName: String
        let segment: Int
        let answer: Data
        let kind: String
        let field: String?
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: RecollectionDraftTests.self)
            .url(forResource: "team-learning-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    private static func root() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData("recollection-drafts-v1.json")) as? [String: Any])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private static func vault() throws -> RecollectionDraftValidator.Vault {
        let vault = try XCTUnwrap(root()["vault"] as? [String: Any])
        let files = try XCTUnwrap(vault["files"] as? [[String: String]]).map {
            (filename: $0["filename"] ?? "", contents: $0["contents"] ?? "")
        }
        return RecollectionDraftValidator.Vault(
            index: VaultModelIndex(vaultName: try XCTUnwrap(vault["name"] as? String), files: files),
            equipmentTypes: try XCTUnwrap(vault["equipment_types"] as? [String]), coreFiles: files)
    }

    private static func cases() throws -> [Case] {
        let raw = try XCTUnwrap(root()["cases"] as? [[String: Any]])
        return try raw.map { item in
            let expected = try XCTUnwrap(item["expected"] as? [String: Any])
            let recording = ExperienceRecording(
                id: try XCTUnwrap(item["recordingID"] as? String), createdAt: Date(timeIntervalSince1970: 1_795_600_000),
                duration: try XCTUnwrap(item["duration"] as? Int), transcript: try XCTUnwrap(item["transcript"] as? String),
                redactions: [], vaultId: "fixture-appliances")
            return Case(name: try XCTUnwrap(item["name"] as? String), recording: recording,
                        segments: try decode([RecollectionDraft.Span].self, try XCTUnwrap(item["segments"])),
                        answers: try XCTUnwrap(item["answers"] as? [Any]).map { try JSONSerialization.data(withJSONObject: $0) },
                        drafts: try decode([RecollectionDraft].self, try XCTUnwrap(expected["drafts"])),
                        siteNotes: try decode([RecollectionSiteNote].self, try XCTUnwrap(expected["siteNotes"])))
        }
    }

    private static func refusalCases() throws -> [RefusalCase] {
        try XCTUnwrap(root()["refusals"] as? [[String: Any]]).map { item in
            let refusal = try XCTUnwrap(item["refusal"] as? [String: Any])
            return RefusalCase(name: try XCTUnwrap(item["name"] as? String), caseName: try XCTUnwrap(item["case"] as? String),
                               segment: item["segment"] as? Int ?? 0,
                               answer: try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["answer"])),
                               kind: try XCTUnwrap(refusal["kind"] as? String), field: refusal["field"] as? String)
        }
    }

    private static func named(_ name: String) throws -> Case {
        try XCTUnwrap(cases().first { $0.name == name }, name)
    }

    private final class StubModel: RecollectionDraftModel {
        var answers: [Data?]
        var requests: [String] = []
        var systems: [String] = []
        init(_ answers: [Data?]) { self.answers = answers }
        func extract(system: String, transcript: String, schema: [String: Any]) async -> Data? {
            systems.append(system)
            requests.append(transcript)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private static let reviewer = RecollectionDrafter.Context(isReviewerDevice: true, medicalComplianceMode: false)

    private func drafter(_ model: StubModel, context: RecollectionDrafter.Context = reviewer) -> RecollectionDrafter {
        let drafter = RecollectionDrafter(model: model)
        drafter.context = { context }
        return drafter
    }

    private func drafted(_ item: Case, answers: [Data?]? = nil) async throws -> (RecollectionDrafts, StubModel) {
        let model = StubModel(answers ?? item.answers)
        switch await drafter(model).draft(item.recording, vault: try Self.vault()) {
        case .success(let drafts): return (drafts, model)
        case .failure(let refusal): XCTFail("\(item.name) refused: \(refusal)"); throw refusal
        }
    }

    // MARK: - The shared schema

    func testTheSchemaIsTheContractsSchema() throws {
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixtureData("recollection-draft-schema-v1.json")) as? NSDictionary)
        XCTAssertEqual(NSDictionary(dictionary: RecollectionDraftRules.jsonSchema), file)
        XCTAssertEqual(RecollectionField.allCases.map(\.rawValue),
                       ["model", "equipmentType", "symptom", "findings", "tried", "fix", "outcome", "siteNote"])
        XCTAssertEqual(RecollectionField.tried.limit, 500)
        XCTAssertEqual(RecollectionField.outcome.limit, 120)
        XCTAssertNil(RecollectionField.siteNote.limit)
    }

    // MARK: - The ten recollections

    func testTheTenRecollectionsCoverThePlan() throws {
        let cases = try Self.cases()
        XCTAssertEqual(cases.count, 10)
        XCTAssertEqual(cases.map(\.name), [
            "one-case", "three-cases", "no-model", "site-mentioned", "safety-relevant-fix", "not-a-case",
            "model-change-without-marker", "unsupported-field-stays-empty", "over-limit-outcome",
            "equipment-type-not-listed",
        ])
    }

    func testEachRecollectionSegmentsAsTheFixtureSays() throws {
        let index = try Self.vault().index
        for item in try Self.cases() {
            let segments = RecollectionSegmenter.segments(in: item.recording.transcript, index: index)
            XCTAssertEqual(segments.map(\.span), item.segments, item.name)
        }
    }

    func testEachRecollectionDraftsExactlyTheExpectedCandidates() async throws {
        for item in try Self.cases() {
            let (result, model) = try await drafted(item)
            XCTAssertEqual(result.drafts, item.drafts, item.name)
            XCTAssertEqual(result.siteNotes, item.siteNotes, item.name)
            XCTAssertEqual(result.refused, [], item.name)
            XCTAssertEqual(model.requests.count, item.segments.count, "one extraction per segment: \(item.name)")
            for (request, segment) in zip(model.requests, result.segments) {
                XCTAssertTrue(request.contains("<<<\n" + segment.text + "\n>>>"), item.name)
                XCTAssertTrue(request.contains("dryer; dishwasher; walk-in cooler"), item.name)
            }
        }
    }

    func testEveryFilledFieldIsCoveredBySpansAndNothingIsInvented() throws {
        for item in try Self.cases() {
            let transcript = Array(item.recording.transcript.unicodeScalars)
            for draft in item.drafts {
                XCTAssertFalse(draft.fields.isEmpty, item.name)
                for (name, field) in draft.fields {
                    XCTAssertFalse(field.spans.isEmpty, "\(item.name) \(name)")
                    for span in field.spans {
                        XCTAssertTrue(draft.segment.start <= span.start && span.end <= draft.segment.end, "\(item.name) \(name)")
                    }
                    let said = Set(RecollectionDraftRules.words(field.spans.map {
                        RecollectionDraftRules.said($0, in: transcript)
                    }.joined(separator: " ")))
                    XCTAssertTrue(RecollectionDraftRules.words(field.text).allSatisfy { RecollectionDraftRules.covered($0, by: said) },
                                  "\(item.name) \(name) says more than its spans")
                }
                XCTAssertNil(draft.fields["siteNote"], "a site is never a learning field: \(item.name)")
            }
        }
    }

    func testOneCaseDraftsOneModelCandidate() async throws {
        let item = try Self.named("one-case")
        let (result, _) = try await drafted(item)
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(result.drafts.count, 1)
        XCTAssertEqual(draft.modelToken, "RX-200")
        XCTAssertEqual(draft.subject?.entrySubject, .model(modelToken: "RX-200", equipmentType: "dryer"))
        XCTAssertEqual(draft.text(.outcome), "Fixed it every time")
        XCTAssertEqual(draft.recording.segment, 0..<48, "the whole recording")

        let candidate = try draft.candidate(from: item.recording, author: "Fixture Technician",
                                            index: try Self.vault().index).get()
        XCTAssertEqual(candidate.origin, .recollection)
        XCTAssertEqual(candidate.evidence.recording, draft.recording)
        XCTAssertEqual(candidate.modelToken, "RX-200")
        XCTAssertEqual(candidate.finding, "The exhaust fan wheel was cracked")
        XCTAssertEqual(candidate.tried, "Checked the vent run and the lint screen first, both clear")
        XCTAssertEqual(candidate.outcome, "Fixed it every time")
        XCTAssertEqual(candidate.vaultId, "fixture-appliances")
        XCTAssertNil(candidate.jobReference)
    }

    func testThreeCasesInOneRecordingDraftThreeCandidatesEachWithItsOwnPart() async throws {
        let (result, _) = try await drafted(try Self.named("three-cases"))
        XCTAssertEqual(result.drafts.map(\.modelToken), ["RX-200", "DW-450", "WC-900"])
        XCTAssertEqual(result.drafts.map(\.recording.segment), [0..<19, 23..<46, 51..<75])
        for segment in result.segments {
            XCTAssertFalse(segment.text.lowercased().contains("next case"), "the marker is in no case")
        }
    }

    func testNoModelDraftsASymptomSubjectWithinTheListedType() async throws {
        let (result, _) = try await drafted(try Self.named("no-model"))
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertNil(draft.modelToken)
        XCTAssertNil(draft.field(.model))
        XCTAssertEqual(draft.subject?.entrySubject, .symptom(equipmentType: "dryer", phrase: "The drum squeaks on start up"))
    }

    func testASiteIsSplitIntoASiteNoteAndNeverReachesTheLearning() async throws {
        let item = try Self.named("site-mentioned")
        let (result, _) = try await drafted(item)
        XCTAssertEqual(result.siteNotes.map(\.text), ["Elm Row depot kitchen"])
        let draft = try XCTUnwrap(result.drafts.first)
        let candidate = try draft.candidate(from: item.recording, author: "Fixture Technician").get()
        let carried = [candidate.finding, candidate.symptom, candidate.fix, candidate.tried, candidate.outcome,
                       candidate.spokenModel, candidate.equipment?.heading].compactMap { $0 }.joined(separator: " ")
        XCTAssertFalse(carried.contains("Elm Row"))
        XCTAssertFalse(draft.fields.values.contains { $0.text.contains("Elm Row") })
    }

    func testASafetyRelevantFixIsDraftedWholeAndFlaggedForTheReviewer() async throws {
        let item = try Self.named("safety-relevant-fix")
        let (result, _) = try await drafted(item)
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertEqual(draft.text(.tried), "Jumpered the high limit to prove the burner lit, then took the jumper off")
        XCTAssertEqual(draft.safetyTerms, ["jumper", "jumpered"])
        // The review asks a second time before a safety departure is approved.
        let candidate = try draft.candidate(from: item.recording, author: "Fixture Technician").get()
        let approval = LearningReview.approve(candidate, approver: .init(name: "Fixture Reviewer", role: "Service Manager"),
                                              subject: draft.subject?.entrySubject, equipmentTypes: try Self.vault().equipmentTypes,
                                              context: .init(isReviewerDevice: true), now: Date(timeIntervalSince1970: 1_795_700_000))
        guard case .failure(.safetyConfirmationNeeded(let finding)) = approval else {
            return XCTFail("expected the safety confirmation, got \(approval)")
        }
        XCTAssertTrue(finding.terms.contains("jumpered"))
    }

    func testARecordingThatIsNotACaseDraftsNothing() async throws {
        let (result, model) = try await drafted(try Self.named("not-a-case"))
        XCTAssertEqual(result.drafts, [])
        XCTAssertEqual(result.siteNotes, [])
        XCTAssertEqual(result.refused, [])
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(result.segments.map(\.text), ["Just testing. Testing one two three."], "that's all ends it")
    }

    func testAModelChangeWithoutAMarkerSplitsTheCase() async throws {
        let (result, _) = try await drafted(try Self.named("model-change-without-marker"))
        XCTAssertEqual(result.segments.map(\.modelName), ["RX-200", "RX-300"])
        XCTAssertEqual(result.drafts.map(\.modelToken), ["RX-200", "RX-300"])
        let fix = try XCTUnwrap(result.drafts.first?.field(.fix))
        XCTAssertEqual(fix.text, "Fit the updated switch kit", "a paraphrase gives way to the words said")
        XCTAssertTrue(fix.verbatim)
    }

    func testAFieldTheTranscriptDoesNotSupportStaysEmpty() async throws {
        let item = try Self.named("unsupported-field-stays-empty")
        let (result, _) = try await drafted(item)
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertNil(draft.field(.tried))
        XCTAssertNil(draft.field(.findings))
        let candidate = try draft.candidate(from: item.recording, author: "Fixture Technician").get()
        XCTAssertNil(candidate.tried)
        XCTAssertEqual(candidate.finding, "Changed the rinse aid dispenser", "the fix stands in for the finding")
    }

    func testAnOverLimitOutcomeIsHeldBackAndNeverCut() async throws {
        let item = try Self.named("over-limit-outcome")
        let (result, _) = try await drafted(item)
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertNil(draft.field(.outcome))
        let held = try XCTUnwrap(draft.heldBack.first)
        XCTAssertEqual(held.field, .outcome)
        XCTAssertEqual(held.reason, .overLimit)
        XCTAssertEqual(held.limit, 120)
        XCTAssertGreaterThan(held.count ?? 0, 120)
        XCTAssertFalse(held.spans.isEmpty, "the reviewer can still read it")
        XCTAssertNil(try draft.candidate(from: item.recording, author: "Fixture Technician").get().outcome)
    }

    func testAnEquipmentTypeThatIsNotListedDraftsNoSymptomSubject() async throws {
        let (result, _) = try await drafted(try Self.named("equipment-type-not-listed"))
        let draft = try XCTUnwrap(result.drafts.first)
        XCTAssertNil(draft.subject)
        XCTAssertNil(draft.field(.equipmentType))
        XCTAssertEqual(draft.heldBack.map(\.reason), [.notListed])
        XCTAssertEqual(draft.heldBack.first?.text, "ice maker")
    }

    // MARK: - Refusals

    func testTheValidatorRefusesWhatTheContractRefuses() throws {
        let cases = try Self.cases()
        let vault = try Self.vault()
        let refusals = try Self.refusalCases()
        XCTAssertEqual(Set(refusals.map(\.kind)),
                       ["malformed", "unsupported", "quoteNotFound", "siteInLearning", "controlCharacter"])
        for refusal in refusals {
            let item = try XCTUnwrap(cases.first { $0.name == refusal.caseName })
            let outcome = RecollectionDraftValidator.validate(
                answer: refusal.answer, segment: item.segments[refusal.segment],
                transcript: Array(item.recording.transcript.unicodeScalars), duration: item.recording.duration,
                recordingID: item.recording.id, vault: vault)
            guard case .failure(let reason) = outcome else {
                XCTFail("\(refusal.name) was not refused"); continue
            }
            XCTAssertEqual(reason.kind, refusal.kind, refusal.name)
            XCTAssertEqual(reason.field?.rawValue, refusal.field, refusal.name)
        }
    }

    func testAnAnswerThatInventsAFieldDraftsNothingForItsCaseAndTheOthersStillDraft() async throws {
        let item = try Self.named("three-cases")
        var invented = try XCTUnwrap(JSONSerialization.jsonObject(with: item.answers[1]) as? [String: Any])
        invented["tried"] = ["text": "Checked the pump impeller", "quotes": [String]()]
        var answers: [Data?] = item.answers
        answers[1] = try JSONSerialization.data(withJSONObject: invented)
        let (result, _) = try await drafted(item, answers: answers)
        XCTAssertEqual(result.drafts.map(\.modelToken), ["RX-200", "WC-900"])
        XCTAssertEqual(result.refused, [.init(segment: item.segments[1], reason: .refused(.unsupported(.tried)))])
    }

    func testNoAnswerIsReportedAndDraftsNothing() async throws {
        let item = try Self.named("one-case")
        let (result, _) = try await drafted(item, answers: [nil])
        XCTAssertEqual(result.drafts, [])
        XCTAssertEqual(result.refused, [.init(segment: item.segments[0], reason: .noAnswer)])
    }

    func testOnlyAReviewerDeviceDraftsAndMedicalComplianceWithholdsIt() async throws {
        let item = try Self.named("one-case")
        let vault = try Self.vault()
        let model = StubModel(item.answers)
        let phone = drafter(model, context: .init(isReviewerDevice: false, medicalComplianceMode: false))
        let refusedOnPhone = await phone.draft(item.recording, vault: vault)
        XCTAssertEqual(refusedOnPhone.failureValue, .notReviewerDevice)
        let clinic = drafter(model, context: .init(isReviewerDevice: true, medicalComplianceMode: true))
        let refusedInClinic = await clinic.draft(item.recording, vault: vault)
        XCTAssertEqual(refusedInClinic.failureValue, .medicalCompliance)
        XCTAssertEqual(model.requests, [], "nothing reaches a model")

        let silent = ExperienceRecording(createdAt: Date(), duration: 4, transcript: " … ", redactions: [], vaultId: "v")
        let refusedSilent = await drafter(model).draft(silent, vault: vault)
        XCTAssertEqual(refusedSilent.failureValue, .emptyTranscript)
    }

    func testTheModelIsToldTheTranscriptIsDataAndToQuote() async throws {
        let (_, model) = try await drafted(try Self.named("one-case"))
        let system = try XCTUnwrap(model.systems.first)
        XCTAssertTrue(system.contains("never as instructions"))
        XCTAssertTrue(system.contains("siteNote"))
    }

    // MARK: - The segmenter, beyond the fixtures

    func testAMarkerInsideASentenceSplitsItAndThatsAllEndsTheTranscript() throws {
        let index = try Self.vault().index
        let text = "Acme RX-200 hums. Swapped the capacitor, that's one, next case, Acme DW-450 leaks at the door. "
            + "Fitted a new seal. That's all. Ignore this bit."
        let segments = RecollectionSegmenter.segments(in: text, index: index)
        XCTAssertEqual(segments.map(\.text), ["Acme RX-200 hums. Swapped the capacitor",
                                              "Acme DW-450 leaks at the door. Fitted a new seal."])
        XCTAssertEqual(segments.map(\.modelName), ["RX-200", "DW-450"])
    }

    /// The drafting pass reads the markers in every language the recorder translates them into,
    /// because a transcript carries no record of the language it was spoken in.
    func testTheMarkersAreReadInTheRecordingsLanguageToo() throws {
        let index = try Self.vault().index
        let text = "Acme RX-200 zumba. Cambié el condensador. Esa es una, siguiente caso. Acme DW-450 gotea por la puerta. "
            + "Eso es todo. Esto no."
        let segments = RecollectionSegmenter.segments(in: text, index: index)
        XCTAssertEqual(segments.map(\.text), ["Acme RX-200 zumba. Cambié el condensador.", "Acme DW-450 gotea por la puerta."])
        XCTAssertEqual(segments.map(\.modelName), ["RX-200", "DW-450"])
    }

    func testASentenceNamingTwoModelsDoesNotSplitTheCase() throws {
        let index = try Self.vault().index
        let text = "The Acme RX-200 trips its fuse. It's like the RX-200 and the RX-300 share the fan. Swapped the fan."
        let segments = RecollectionSegmenter.segments(in: text, index: index)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.span, RecollectionDraft.Span(start: 0, end: text.unicodeScalars.count))
    }

    func testADecimalIsNotASentenceEnd() {
        let scalars = Array("Read 3.5 amps on the fan. Then it stopped.".unicodeScalars)
        XCTAssertEqual(RecollectionSegmenter.sentences(in: scalars).count, 2)
    }

    func testTheSecondsAreEstimatedFromTheTranscript() {
        XCTAssertEqual(RecollectionDraftRules.seconds(of: .init(start: 0, end: 50), transcriptLength: 100, duration: 60), 0..<30)
        XCTAssertEqual(RecollectionDraftRules.seconds(of: .init(start: 50, end: 100), transcriptLength: 100, duration: 60), 30..<60)
        XCTAssertEqual(RecollectionDraftRules.seconds(of: .init(start: 99, end: 100), transcriptLength: 100, duration: 0), 0..<1)
    }

    func testQuotesAreFoundOnWholeWordsWhateverTheCaseAndPunctuation() {
        let transcript = Array("Swapped the fan-wheel, then RAN it.".unicodeScalars)
        let whole = RecollectionDraft.Span(start: 0, end: transcript.count)
        XCTAssertEqual(RecollectionDraftRules.find(quote: "the fan wheel", in: transcript, segment: whole),
                       .init(start: 8, end: 21))
        XCTAssertEqual(RecollectionDraftRules.find(quote: "ran it", in: transcript, segment: whole), .init(start: 28, end: 34))
        XCTAssertNil(RecollectionDraftRules.find(quote: "an it", in: transcript, segment: whole), "whole words only")
        XCTAssertTrue(RecollectionDraftRules.related("dryers", "dryer"))
        XCTAssertTrue(RecollectionDraftRules.related("replaced", "replace"))
        XCTAssertFalse(RecollectionDraftRules.related("fitted", "fit"))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
