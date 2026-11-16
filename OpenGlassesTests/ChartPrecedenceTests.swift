import XCTest
@testable import OpenGlasses

/// Plan LX P0 §6 — printed beats recognised beats computed beats chart; a disagreement is counted,
/// never spoken.
final class ChartPrecedenceTests: XCTestCase {

    private typealias F = ChartFixtures

    private func chart(_ x: Double = 85) -> ChartValue {
        guard case .value(let value, _) = ChartLookup.value(in: F.validated(), series: "67", at: x) else { fatalError() }
        return value
    }

    func testPrintedBeatsRecognisedBeatsComputedBeatsChart() {
        XCTAssertEqual(ChartPrecedence.choose(printed: 14, recognised: (16, true), computed: 17, chart: chart())?.source, .printed)
        XCTAssertEqual(ChartPrecedence.choose(printed: nil, recognised: (16, true), computed: 17, chart: chart())?.source, .recognisedCell)
        XCTAssertEqual(ChartPrecedence.choose(printed: nil, recognised: nil, computed: 17, chart: chart())?.source, .computed)
        let fromChart = ChartPrecedence.choose(printed: nil, recognised: nil, computed: nil, chart: chart())
        XCTAssertEqual(fromChart?.source, .chart)
        XCTAssertEqual(fromChart?.value, 15)
        XCTAssertEqual(fromChart?.mentionsChart, true)
        XCTAssertNil(ChartPrecedence.choose(printed: nil, recognised: nil, computed: nil, chart: nil))
    }

    func testAnUncertainCellNeverAnswers() {
        XCTAssertEqual(ChartPrecedence.choose(printed: nil, recognised: (16, false), computed: nil, chart: chart())?.source, .chart)
        XCTAssertNil(ChartPrecedence.choose(printed: nil, recognised: (16, false), computed: nil, chart: nil))
    }

    func testADisagreementIsCountedNotSpoken() {
        // The chart says about 15 (step 5); the printed table says 30: more than two steps apart.
        let decision = ChartPrecedence.choose(printed: 30, recognised: nil, computed: nil, chart: chart())
        XCTAssertEqual(decision?.source, .printed)
        XCTAssertEqual(decision?.value, 30)
        XCTAssertEqual(decision?.chartDisagreed, true)
        XCTAssertEqual(decision?.mentionsChart, false, "the chart is not mentioned")
        var tally = ChartPrecedence.DisagreementTally()
        tally.note(decision)
        tally.note(ChartPrecedence.choose(printed: 20, recognised: nil, computed: nil, chart: chart()))
        XCTAssertEqual(tally.count, 1, "within two steps is not a disagreement")
    }

    func testTheOrderIsComparable() {
        XCTAssertLessThan(ChartPrecedence.Source.printed, .recognisedCell)
        XCTAssertLessThan(ChartPrecedence.Source.computed, .chart)
    }
}

/// Plan LX P0 §7 — which charts always send the technician to the page.
final class ChartSafetyClassTests: XCTestCase {

    func testChargeDeratingAndGasCaptionsAreCritical() {
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 9. Charging chart, model QMX90", titles: [], units: []),
                       .critical(.refrigerantCharge))
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 4", titles: ["Target superheat", "Outdoor temperature"], units: ["°F"]),
                       .critical(.refrigerantCharge))
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 21. Conductor derating", titles: [], units: []),
                       .critical(.electricalLimit))
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 30. Manifold pressure by altitude", titles: [], units: ["in. w.c."]),
                       .critical(.fuelGas))
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 31", titles: ["Flue temperature"], units: []),
                       .critical(.combustion))
    }

    func testCurrentAgainstTemperatureIsAnElectricalLimit() {
        XCTAssertEqual(ChartSafetyClass.classify(caption: nil, titles: ["Allowed current", "Ambient temperature"], units: ["A", "°C"]),
                       .critical(.electricalLimit))
    }

    func testAFanCurveIsNotCritical() {
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 12. Blower performance", titles: ["Airflow", "External static pressure"],
                                                 units: ["CFM", "in. w.c."]), .ordinary)
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Figure 13. Pump curve", titles: ["Flow", "Head"], units: ["gpm", "ft"]), .ordinary)
        XCTAssertFalse(ChartSafetyClass.classify(caption: "Discharge air temperature", titles: [], units: []).isCritical,
                       "discharge is not charge")
    }

    func testAnotherLanguagesWordsAreCritical() {
        XCTAssertEqual(ChartSafetyClass.classify(caption: "Abbildung 9. Überhitzung", titles: [], units: [],
                                                 rule: .prefixStem(.german)), .critical(.refrigerantCharge))
    }

    func testTheImportedChargingChartIsCritical() {
        XCTAssertTrue(ChartSafetyClass.classify(ChartFixtures.chargingCandidate()).isCritical)
    }
}

/// Plan LX P0 §9 — what a chart reading's cache keeps, and its key.
final class ChartCachePolicyTests: XCTestCase {

    private let prompt = ChartCachePolicy.Prompt(system: "Write the chart out as data.", user: "Figure 9, page 41.",
                                                 schema: #"{"type":"object"}"#, version: 1)
    private let image = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheSameImageAndPromptHitWhicheverModelReadIt() {
        let key = ChartCachePolicy.key(image: image, prompt: prompt)
        XCTAssertEqual(key, ChartCachePolicy.key(image: image, prompt: prompt))
        guard case .store(let entry) = ChartCachePolicy.decide(.complete(ChartFixtures.chargingReading(), verdict: .usable),
                                                               key: key, modelId: "model-a", date: now) else {
            return XCTFail("a complete reply is stored")
        }
        XCTAssertEqual(ChartCachePolicy.lookup(key, in: [entry])?.modelId, "model-a", "the model is recorded, not keyed")
        XCTAssertEqual(key.imageHash.count, 64)
    }

    func testAChangedPromptOrImageMisses() {
        let key = ChartCachePolicy.key(image: image, prompt: prompt)
        var changed = prompt
        changed.version = 2
        XCTAssertNotEqual(ChartCachePolicy.key(image: image, prompt: changed), key)
        changed = prompt
        changed.user = "Figure 9, page 42."
        XCTAssertNotEqual(ChartCachePolicy.key(image: image, prompt: changed), key)
        XCTAssertNotEqual(ChartCachePolicy.key(image: image + Data([4]), prompt: prompt), key)
        // Moving text from one part to the next is a different prompt.
        let moved = ChartCachePolicy.Prompt(system: "Write the chart out as data. Figure 9,", user: " page 41.",
                                            schema: prompt.schema, version: 1)
        XCTAssertNotEqual(ChartCachePolicy.key(image: image, prompt: moved), key)
        guard case .store(let entry) = ChartCachePolicy.decide(.complete(ChartFixtures.chargingReading(), verdict: .usable),
                                                               key: key, modelId: "m", date: now) else { return XCTFail() }
        XCTAssertNil(ChartCachePolicy.lookup(ChartCachePolicy.key(image: image, prompt: changed), in: [entry]))
    }

    func testACutOffAFailedAndAnUndecodableReplyAreNotStored() {
        let key = ChartCachePolicy.key(image: image, prompt: prompt)
        for reply in [ChartCachePolicy.Reply.cutOff, .failed, .undecodable] {
            XCTAssertEqual(ChartCachePolicy.decide(reply, key: key, modelId: "m", date: now), .retryLater, "\(reply)")
        }
        XCTAssertFalse(ChartCachePolicy.mayRetry(lastAttempt: now, now: now.addingTimeInterval(3600)), "at most once a day")
        XCTAssertTrue(ChartCachePolicy.mayRetry(lastAttempt: now, now: now.addingTimeInterval(24 * 3600)))
        XCTAssertTrue(ChartCachePolicy.mayRetry(lastAttempt: nil, now: now))
    }

    func testARejectedReadingIsStoredAsRejectedAndReadAgainReplacesIt() {
        let key = ChartCachePolicy.key(image: image, prompt: prompt)
        let verdict = ChartReadingValidator.check(ChartFixtures.chargingReading(series: [
            .init(label: "67", parameter: 67, points: ChartFixtures.points([28, 22, 15, 9, 6, 90])),
        ]), against: ChartFixtures.chargingCandidate())
        XCTAssertEqual(ChartCachePolicy.Verdict(verdict), .rejected)
        guard case .store(let rejected) = ChartCachePolicy.decide(.complete(ChartFixtures.chargingReading(), verdict: .init(verdict)),
                                                                  key: key, modelId: "m", date: now) else {
            return XCTFail("a rejected complete reading is stored, so the misread is not paid for again")
        }
        XCTAssertEqual(rejected.verdict, .rejected)
        guard case .store(let again) = ChartCachePolicy.decide(.complete(ChartFixtures.chargingReading(), verdict: .usable),
                                                               key: key, modelId: "m", date: now.addingTimeInterval(60)) else {
            return XCTFail()
        }
        let entries = ChartCachePolicy.replacing([rejected], with: again)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(ChartCachePolicy.lookup(key, in: entries)?.verdict, .usable)
    }
}
