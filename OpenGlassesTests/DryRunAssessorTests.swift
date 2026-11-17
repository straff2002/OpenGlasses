import XCTest
@testable import OpenGlasses

/// A test passes only on the success path with real values, an answer and no limit hit.
final class DryRunAssessorTests: XCTestCase {

    private func trace(outcome: DryRunTrace.Outcome = .completed, steps: [DryRunTrace.Step],
                       spoken: String = "High tide is at 14:05.", requests: Int = 1) -> DryRunTrace {
        DryRunTrace(skill: "tide", outcome: outcome, steps: steps, spoken: spoken, requestsMade: requests,
                    hostsContacted: requests > 0 ? ["tides.example.net"] : [], elapsed: 0.8)
    }

    private let okHTTP = DryRunTrace.Step(path: "steps[0]", kind: .http, status: .ok, host: "tides.example.net",
                                          httpStatus: 200, bytes: 512, redirectHops: 0)
    private let found = DryRunTrace.Step(path: "steps[1]", kind: .extract, status: .ok, value: "14:05")

    func testTheSuccessPathPasses() {
        let assessment = DryRunAssessor.assess(trace(steps: [okHTTP, found]))
        XCTAssertTrue(assessment.passed)
        XCTAssertTrue(DryRunAssessor.repairLines(assessment).isEmpty)
    }

    func testAnEmptyExtractFails() {
        let missed = DryRunTrace.Step(path: "steps[1]", kind: .extract, status: .missed, value: "")
        let assessment = DryRunAssessor.assess(trace(steps: [okHTTP, missed], spoken: "I couldn't find a tide."))
        XCTAssertEqual(assessment.reasons, [.extractEmpty(path: "steps[1]")])
    }

    func testAFailedRequestFails() {
        let failed = DryRunTrace.Step(path: "steps[0]", kind: .http, status: .failed, host: "tides.example.net",
                                      httpStatus: 404, bytes: 0, redirectHops: 0, error: "status")
        let assessment = DryRunAssessor.assess(trace(steps: [failed]))
        XCTAssertEqual(assessment.reasons, [.httpFailed(path: "steps[0]", status: 404, error: "status")])
        XCTAssertTrue(DryRunAssessor.repairLines(assessment)[0].contains("status 404"))
    }

    func testUnresolvedPlaceholdersAndSilenceFail() {
        XCTAssertEqual(DryRunAssessor.assess(trace(steps: [okHTTP, found], spoken: "High tide at {{time}}")).reasons,
                       [.unresolvedPlaceholder])
        XCTAssertEqual(DryRunAssessor.assess(trace(steps: [okHTTP, found], spoken: "  ")).reasons, [.noAnswer])
    }

    func testALimitHitFailsEvenWhenItAnswered() {
        let tooLarge = DryRunTrace.Step(path: "steps[0]", kind: .http, status: .failed, host: "tides.example.net",
                                        error: "too_large")
        let reasons = DryRunAssessor.assess(trace(steps: [tooLarge])).reasons
        XCTAssertTrue(reasons.contains(.limitHit("too_large")))
    }

    func testARunThatNeverCalledTheServiceFails() {
        XCTAssertEqual(DryRunAssessor.assess(trace(steps: [], requests: 0)).reasons, [.noRequest])
    }

    func testAnIncompleteRunFails() {
        let blocked = DryRunAssessor.assess(trace(outcome: .blockedSample(["email"]), steps: [], spoken: "", requests: 0))
        XCTAssertEqual(blocked.reasons, [.didNotComplete(.blockedSample(["email"]))])
        let timedOut = DryRunAssessor.assess(trace(outcome: .timedOut, steps: [okHTTP]))
        XCTAssertFalse(timedOut.passed)
    }

    func testSimulatedAndPreviewStepsDoNotFailATest() {
        let remember = DryRunTrace.Step(path: "steps[2]", kind: .remember, status: .simulated, value: "last_tide")
        let display = DryRunTrace.Step(path: "steps[3]", kind: .display, status: .previewOnly, value: "Tide")
        XCTAssertTrue(DryRunAssessor.assess(trace(steps: [okHTTP, found, remember, display])).passed)
    }
}
