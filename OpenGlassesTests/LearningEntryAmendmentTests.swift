import XCTest
@testable import OpenGlasses

/// Plan NF P0 — the crew-experience amendment to the learning entry (`Contracts/team-learning.md`
/// §5): origin `recollection`, `faultCode`, `tried`, `outcome` and the symptom subject. Older files
/// read exactly as before, and an entry without the new fields is retrieved by the same text.
/// Invented models and codes only.
@MainActor
final class LearningEntryAmendmentTests: XCTestCase {

    private static let approvedAt = Date(timeIntervalSince1970: 1_795_564_800)

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// An entry as `LearningEntryStore` wrote it before the amendment, key for key.
    private let oldShape = """
    [{"approvedAt":"2026-11-01T00:00:00Z","approvedByName":"Avery Example","approvedByRole":"Supervisor",
      "authorIsApprover":false,"candidateID":"0123456789abcdef0123456789abcdef","confirmedJobCount":1,
      "contradictsSafetyNote":false,"entryID":"fedcba9876543210fedcba9876543210","finding":"Reseat the harness",
      "fix":"Reseated the harness","origin":"spoken","sourceJobIDs":["job-1"],
      "subject":{"kind":"model","modelToken":"QXRT-990"},"symptom":"Trips on start","vaultIDs":["fixture-crew-units"]}]
    """

    func testAnOldShapeFileReadsAsBefore() throws {
        let entries = try decoder().decode([LearningEntry].self, from: Data(oldShape.utf8))
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "fedcba9876543210fedcba9876543210")
        XCTAssertEqual(entry.origin, .spoken)
        XCTAssertNil(entry.faultCode)
        XCTAssertNil(entry.tried)
        XCTAssertNil(entry.outcome)
        XCTAssertEqual(entry.subject, .model(modelToken: "QXRT-990"))
        XCTAssertEqual(LearningCorpus.documentText(entry),
                       "Model: QXRT-990\nSymptom: Trips on start\nFinding: Reseat the harness\nFix: Reseated the harness")
        // Written again, an entry without the new fields carries none of their keys.
        let written = String(decoding: try encoder().encode(entries), as: UTF8.self)
        for key in ["faultCode", "tried", "outcome"] { XCTAssertFalse(written.contains("\"\(key)\""), key) }
    }

    func testTheNewFieldsAndOriginRoundTrip() throws {
        let entry = LearningEntry(subject: .model(modelToken: "QXRT-990", manufacturer: "Fixturetherm"),
                                  vaultIDs: ["fixture-crew-units"], finding: "E999: Reseated the harness at the plug",
                                  symptom: "E999: Trips on start", fix: "Reseated the harness at the plug",
                                  faultCode: "E999", tried: "Pressure switch", outcome: "fixed it most times",
                                  approvedAt: Self.approvedAt, approvedByRole: "Service manager", approvedByName: "Service manager",
                                  origin: .recollection)
        let back = try decoder().decode(LearningEntry.self, from: try encoder().encode(entry))
        XCTAssertEqual(back, entry)
        XCTAssertEqual(back.origin, .recollection)
        XCTAssertNil(back.confirmedJobCount, "a recollection was confirmed on no job")
    }

    func testTheSymptomSubjectRoundTripsAndCitesItsEquipmentType() throws {
        let subject = LearningEntry.Subject.symptom(equipmentType: "walk-in cooler", phrase: "Door frame sweats")
        let data = try encoder().encode(subject)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"equipmentType":"walk-in cooler","kind":"symptom","phrase":"Door frame sweats"}"#)
        XCTAssertEqual(try decoder().decode(LearningEntry.Subject.self, from: data), subject)
        XCTAssertEqual(subject.citationSubject, "walk-in cooler")
        XCTAssertNil(subject.modelToken)
        XCTAssertThrowsError(try decoder().decode(LearningEntry.Subject.self, from: Data(#"{"kind":"site","topic":"x"}"#.utf8)))
    }

    func testTheDocumentTextCarriesTheFaultCodeChecksAndHowSure() {
        let entry = LearningEntry(subject: .model(modelToken: "QXRT-990"), vaultIDs: [], finding: "Usually the harness, not the switch",
                                  symptom: "E999: Trips on start", fix: "Reseated the harness", faultCode: "E999",
                                  tried: "Pressure switch continuity", outcome: "fixed it most times",
                                  approvedAt: Self.approvedAt, approvedByRole: "Owner", approvedByName: "Owner", origin: .recollection)
        XCTAssertEqual(LearningCorpus.documentText(entry), """
        Model: QXRT-990
        Fault code: E999
        Symptom: E999: Trips on start
        Checked: Pressure switch continuity
        Finding: Usually the harness, not the switch
        Fix: Reseated the harness
        How sure: fixed it most times
        """)
        XCTAssertEqual(LearningCorpus.subjectModelToken(fromDocumentText: LearningCorpus.documentText(entry)), "QXRT-990")
    }

    func testASymptomEntrysTextNamesItsEquipmentAndNoModel() {
        let entry = LearningEntry(subject: .symptom(equipmentType: "walk-in cooler", phrase: "Door frame sweats"), vaultIDs: [],
                                  finding: "Replaced the heater fuse", approvedAt: Self.approvedAt, approvedByRole: "Owner",
                                  approvedByName: "Owner", origin: .recollection)
        let text = LearningCorpus.documentText(entry)
        XCTAssertEqual(text, "Equipment: walk-in cooler\nSymptom: Door frame sweats\nFinding: Replaced the heater fuse")
        XCTAssertNil(LearningCorpus.subjectModelToken(fromDocumentText: text))
    }

    func testReviewComparesAndCleansASymptomSubject() {
        XCTAssertTrue(LearningReview.sameSubject(.symptom(equipmentType: "Walk-in cooler", phrase: "Door  sweats"),
                                                 .symptom(equipmentType: "walk-in cooler", phrase: "door sweats")))
        XCTAssertFalse(LearningReview.sameSubject(.symptom(equipmentType: "rooftop unit", phrase: "door sweats"),
                                                  .symptom(equipmentType: "walk-in cooler", phrase: "door sweats")))
        XCTAssertFalse(LearningReview.sameSubject(.symptom(equipmentType: "walk-in cooler", phrase: "x"), .practice(topic: "x")))
        XCTAssertEqual(LearningReview.cleanSubject(.symptom(equipmentType: " walk-in cooler ", phrase: "Door\tsweats")),
                       .symptom(equipmentType: "walk-in cooler", phrase: "Door sweats"))
        XCTAssertNil(LearningReview.cleanSubject(.symptom(equipmentType: "  ", phrase: "Door sweats")))
    }

    func testTheUnsignedBundleStillRefusesASubjectItDoesNotCarry() throws {
        // The FP bundle's closed schema names model and practice only: a symptom subject arriving
        // there is refused by name, never half-read.
        let entry = LearningEntry(subject: .symptom(equipmentType: "walk-in cooler", phrase: "Door sweats"), vaultIDs: [],
                                  finding: "Replaced the heater fuse", approvedAt: Self.approvedAt, approvedByRole: "Owner",
                                  approvedByName: "Owner", origin: .recollection)
        let wire = LearningBundle.Entry(entry)
        XCTAssertEqual(wire.origin, .recollection)
        XCTAssertEqual(wire.entry().subject, entry.subject)
        let bundle = LearningBundle(direction: .decisions, organisationLabel: nil, issuedAt: 1_800_000_200, sequence: 1,
                                    entries: [wire])
        guard case .failure(let refusal) = LearningBundle.decode(bundle.encoded()) else {
            return XCTFail("a symptom subject in an unsigned bundle must be refused")
        }
        XCTAssertEqual(refusal, .outOfRange("entries[0].subject.kind"))
    }
}
