import XCTest
@testable import OpenGlasses

/// Validation of a video model's action events (Contracts/recorded-session.md §7.2) against
/// `action-events-v1.json`: reject or repair, never guess.
final class ActionEventValidatorTests: XCTestCase {
    private typealias F = RecordedJobFixtures
    private typealias V = ActionEventValidator
    private func t(_ seconds: Double) -> SessionTime { SessionTime(seconds: seconds) }

    private struct Expected: Decodable {
        struct Kept: Decodable {
            let event: ActionEvent
            let repairs: [String]
        }
        struct Rejected: Decodable, Equatable {
            let index: Int
            let id: String?
            let reason: String
        }
        let kept: [Kept]
        let rejected: [Rejected]
        let view_limitations: [String]
        let partial_view: Bool
    }

    private func context(_ fixture: [String: Any]) throws -> V.Context {
        let span = try XCTUnwrap(fixture["analysedSpan"] as? [String: Any])
        return V.Context(spanFrom: t(try XCTUnwrap(span["from"] as? Double)), spanTo: t(try XCTUnwrap(span["to"] as? Double)),
                         timeline: try F.timeline(fixture["timeline"]), transcript: try F.transcript(fixture["transcript"]))
    }

    private func goldenContext(from: Double = 0, to: Double = 300) throws -> V.Context {
        V.Context(spanFrom: t(from), spanTo: t(to), timeline: try F.goldenTimeline(), transcript: try F.goldenTranscript())
    }

    private func validate(_ json: String, from: Double = 0, to: Double = 300) throws -> V.Result {
        try V.validate(Data(json.utf8), context: goldenContext(from: from, to: to))
    }

    // MARK: - The fixture

    func testEveryFixtureCaseGivesItsResult() throws {
        let fixture = try F.object("action-events-v1")
        let context = try context(fixture)
        let cases = try F.cases(fixture)
        XCTAssertEqual(cases.count, 13)
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let expected: Expected = try F.decoded(item["expected"])
            let result = try V.validate(F.json(item["model_output"]), context: context)
            XCTAssertEqual(result.kept.map(\.event), expected.kept.map(\.event), name)
            XCTAssertEqual(result.kept.map { $0.repairs.map(\.rawValue) }, expected.kept.map(\.repairs), name)
            XCTAssertEqual(result.rejected.map { Expected.Rejected(index: $0.index, id: $0.id, reason: $0.reason.rawValue) },
                           expected.rejected, name)
            XCTAssertEqual(result.viewLimitations, expected.view_limitations, name)
            XCTAssertEqual(result.partialView, expected.partial_view, name)
            XCTAssertEqual(result.events, expected.kept.map(\.event), name)
        }
    }

    func testTheFixtureIsCheckedAgainstTheGoldenJob() throws {
        let fixture = try F.object("action-events-v1")
        XCTAssertEqual(try F.timeline(fixture["timeline"]), try F.goldenTimeline())
        XCTAssertEqual(try F.transcript(fixture["transcript"]), try F.goldenTranscript())
    }

    func testTheFixturesRulesAreTheRulesInTheCode() throws {
        let rules = try XCTUnwrap(F.object("action-events-v1")["rules"] as? [String: Any])
        XCTAssertEqual(rules["confidenceFloor"] as? Double, V.confidenceFloor)
        XCTAssertEqual(rules["actionCharacters"] as? [Int], [1, V.maximumActionCharacters])
        XCTAssertEqual(rules["objectAndToolCharacters"] as? [Int], [0, V.maximumDetailCharacters])
        XCTAssertEqual(rules["idCharacters"] as? [Int], [1, V.maximumIDCharacters])
    }

    // MARK: - What the fixture cannot hold

    func testAnOutputThatIsNotTheShapeIsRefusedWhole() {
        for json in ["", "not json", "[]", "{}", #"{"action_events":{}}"#, #"{"action_events":"none"}"#] {
            XCTAssertThrowsError(try validate(json), json) { XCTAssertEqual($0 as? V.Refusal, .malformed, json) }
        }
    }

    func testAnEmptyListIsAValidAnswer() throws {
        let result = try validate(#"{"action_events":[],"view_limitations":[],"partial_view":false}"#)
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.rejected, [])
        XCTAssertFalse(result.partialView)
    }

    func testLengthsAreCountedInCharactersNotBytes() throws {
        // 200 two-byte characters is 200 characters.
        let action = String(repeating: "\u{E9}", count: 200)
        let result = try validate(#"{"action_events":[{"id":"a1","start":45,"end":58,"action":"\#(action)","evidence":[{"t":46}]}]}"#)
        XCTAssertEqual(result.events.map(\.action), [action])
    }

    func testEvidenceAtTheEdgesOfTheEventIsInsideIt() throws {
        let result = try validate(#"{"action_events":[{"id":"a1","start":45,"end":58,"action":"remove cover","evidence":[{"t":58},{"t":45},{"t":58.001},{"t":44.999}]}]}"#)
        XCTAssertEqual(result.events.first?.evidence.map(\.t), [t(45), t(58)])
        XCTAssertEqual(result.kept.first?.repairs, [.evidenceRemoved])
    }

    func testAnEventOnATimelineWithNoVideoIsRejected() throws {
        var audioOnly = try F.goldenTimeline()
        audioOnly.tracks.removeAll { $0.track == .video }
        let context = V.Context(spanFrom: t(0), spanTo: t(300), timeline: audioOnly, transcript: try F.goldenTranscript())
        let result = try V.validate(Data(#"{"action_events":[{"id":"a1","start":45,"end":58,"action":"remove cover","evidence":[{"t":46}]}]}"#.utf8),
                                    context: context)
        XCTAssertEqual(result.rejected.map(\.reason), [.outsideMedia])
    }

    func testAValidatedEventIsWrittenInTheContractsShape() throws {
        let result = try validate(#"{"action_events":[{"id":"a1","start":45,"end":58,"action":"remove cover","tool":"screwdriver","evidence":[{"t":46}],"utterances":["u3"],"confidence":0.25}]}"#)
        let event = try XCTUnwrap(result.events.first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(decoding: try encoder.encode(event), as: UTF8.self),
                       #"{"action":"remove cover","confidence":0.25,"end":58,"evidence":[{"t":46}],"id":"a1","low_confidence":true,"start":45,"tool":"screwdriver","utterances":["u3"]}"#)
        XCTAssertEqual(try JSONDecoder().decode(ActionEvent.self, from: encoder.encode(event)), event)
    }
}
