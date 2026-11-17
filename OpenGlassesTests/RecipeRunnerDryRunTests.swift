import XCTest
@testable import OpenGlasses

/// The test run of a drafted add-on: the same engine and sandbox, every step traced, memory writes
/// simulated, cards previewed, and sample values screened strictly.
final class RecipeRunnerDryRunTests: XCTestCase {

    private func manifest(steps: [[String: Any]], permissions: [String: Any],
                          parameters: [String: Any] = ["place": ["type": "string", "required": true]]) throws -> RecipeAddOnManifest {
        let data = RecipeAddOnFixtures.file(skills: [[
            "name": "tide", "description": "Use when the wearer asks for the tide.",
            "parameters": parameters, "steps": steps,
        ]], permissions: permissions)
        let report = RecipeAddOnValidator.validate(data: data)
        XCTAssertEqual(report.issues, [])
        return try XCTUnwrap(report.manifest)
    }

    private func context(location: RecipeLocation? = nil) -> RecipeRunContext {
        RecipeRunContext(now: Date(timeIntervalSince1970: 1_794_000_000), timeZone: TimeZone(identifier: "UTC")!,
                         locale: Locale(identifier: "en_NZ"), units: .metric, location: location)
    }

    private var tideSteps: [[String: Any]] {
        [
            ["http": ["method": "GET", "url": "https://tides.example.net/v1/next?place={{place}}", "as": "r"]],
            ["extract": ["from": "r", "jsonpath": "$.next.time", "as": "time"]],
            ["remember": ["key": "last_tide", "value": "{{time}}"]],
            ["display": ["kind": "text", "title": "Next tide", "items": ["{{time}}"]]],
            ["if": ["op": "empty", "var": "time",
                    "then": [["say": "I couldn't find the tide."]],
                    "else": [["say": "High tide is at {{time}}."]]]],
        ]
    }

    func testEveryStepIsTracedAndNothingIsWrittenOrShown() async throws {
        let m = try manifest(steps: tideSteps, permissions: ["network": ["tides.example.net"], "memory": true, "display": true])
        let clock = FakeAddOnClock()
        let transport = FakeAddOnHTTPTransport(clock: clock, json: #"{"next":{"time":"14:05"}}"#)
        transport.latency = 0.4
        let runner = RecipeRunner(transport: transport, clock: clock)
        let trace = await runner.dryRun(m, skill: "tide", arguments: ["place": "Plimmerton"], context: context())

        XCTAssertEqual(trace.outcome, .completed)
        XCTAssertEqual(trace.spoken, "High tide is at 14:05.")
        XCTAssertEqual(trace.requestsMade, 1)
        XCTAssertEqual(trace.hostsContacted, ["tides.example.net"])
        XCTAssertEqual(trace.elapsed, 0.4, accuracy: 0.001)
        XCTAssertEqual(trace.steps.map(\.kind), [.http, .extract, .remember, .display, .branch, .say])
        XCTAssertEqual(trace.steps[0].status, .ok)
        XCTAssertEqual(trace.steps[0].httpStatus, 200)
        XCTAssertEqual(trace.steps[0].bytes, 25)
        XCTAssertEqual(trace.steps[1].value, "14:05")
        XCTAssertEqual(trace.steps[2].status, .simulated)
        XCTAssertEqual(trace.steps[2].value, "last_tide")
        XCTAssertEqual(trace.steps[3].status, .previewOnly)
        XCTAssertEqual(trace.steps[4].value, "else")
        XCTAssertEqual(trace.steps[5].path, "steps[4].else[0]")
        XCTAssertTrue(DryRunAssessor.assess(trace).passed)

        // The same file run for real still hands its writes to the caller: only the test holds them back.
        let real = await runner.run(m, skill: "tide", arguments: ["place": "Plimmerton"], context: context())
        XCTAssertEqual(real.memoryWrites, [RecipeMemoryWrite(key: "last_tide", value: "14:05")])
        XCTAssertNotNil(real.display)
    }

    func testAMissedExtractIsTheFailurePath() async throws {
        let m = try manifest(steps: tideSteps, permissions: ["network": ["tides.example.net"], "memory": true, "display": true])
        let transport = FakeAddOnHTTPTransport(json: #"{"other":1}"#)
        let trace = await RecipeRunner(transport: transport).dryRun(m, skill: "tide", arguments: ["place": "Plimmerton"],
                                                                      context: context())
        XCTAssertEqual(trace.steps[1].status, .missed)
        XCTAssertEqual(DryRunAssessor.assess(trace).reasons, [.extractEmpty(path: "steps[1]")])
    }

    func testRedirectHopsAreCounted() async throws {
        let m = try manifest(steps: Array(tideSteps.prefix(2)) + [["say": "{{time}}"]],
                             permissions: ["network": ["tides.example.net"]])
        let transport = FakeAddOnHTTPTransport { request in
            request.url.path == "/v1/next" ? .redirect(to: "https://tides.example.net/v2/next")
                : .json(#"{"next":{"time":"09:12"}}"#)
        }
        let trace = await RecipeRunner(transport: transport).dryRun(m, skill: "tide", arguments: ["place": "Paekākāriki"],
                                                                      context: context())
        XCTAssertEqual(trace.steps[0].redirectHops, 1)
        XCTAssertEqual(trace.spoken, "09:12")
    }

    func testPersonalDataInASampleBlocksTheTestBeforeAnyRequest() async throws {
        let m = try manifest(steps: [tideSteps[0], ["say": "{{r}}"]], permissions: ["network": ["tides.example.net"]])
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let runner = RecipeRunner(transport: transport)
        let email = await runner.dryRun(m, skill: "tide", arguments: ["place": "jo.person@example.com"], context: context())
        guard case .blockedSample = email.outcome else { return XCTFail("\(email.outcome)") }
        let key = await runner.dryRun(m, skill: "tide", arguments: ["place": "Bearer " + String(repeating: "q", count: 24)],
                                      context: context())
        guard case .blockedSample = key.outcome else { return XCTFail("\(key.outcome)") }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAValueTheWearerToldTheAssistantBlocksTheTest() async throws {
        let m = try manifest(steps: [tideSteps[0], ["say": "{{r}}"]], permissions: ["network": ["tides.example.net"]])
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let trace = await RecipeRunner(transport: transport).dryRun(
            m, skill: "tide", arguments: ["place": "Near 12 Kowhai Grove"], context: context(),
            wearerFacts: ["12 kowhai grove", "NZ"])
        XCTAssertEqual(trace.outcome, .blockedSample(["wearer_fact"]))
        XCTAssertTrue(transport.requests.isEmpty)
        // A fact too short to mean anything ("NZ") doesn't block an ordinary sample.
        let ordinary = await RecipeRunner(transport: transport).dryRun(
            m, skill: "tide", arguments: ["place": "Plimmerton NZ"], context: context(), wearerFacts: ["NZ"])
        XCTAssertEqual(ordinary.outcome, .completed)
    }

    func testLocationIsCoarse() async throws {
        let m = try manifest(steps: [["http": ["method": "GET", "url": "https://tides.example.net/near?lat={{lat}}&lon={{lon}}", "as": "r"]],
                                     ["say": "{{r}}"]],
                             permissions: ["network": ["tides.example.net"], "location": true], parameters: [:])
        let transport = FakeAddOnHTTPTransport(json: #""ok""#)
        _ = await RecipeRunner(transport: transport).dryRun(
            m, skill: "tide", arguments: [:],
            context: context(location: RecipeLocation(latitude: -41.086_643, longitude: 174.865_571)))
        XCTAssertEqual(transport.requests.first?.url.query, "lat=-41.09&lon=174.87")
    }

    func testWrongArgumentsAreReportedNotRun() async throws {
        let m = try manifest(steps: [tideSteps[0], ["say": "{{r}}"]], permissions: ["network": ["tides.example.net"]])
        let transport = FakeAddOnHTTPTransport(json: "{}")
        let trace = await RecipeRunner(transport: transport).dryRun(m, skill: "tide", arguments: [:], context: context())
        guard case .invalidArguments = trace.outcome else { return XCTFail("\(trace.outcome)") }
        let unknown = await RecipeRunner(transport: transport).dryRun(m, skill: "nope", arguments: [:], context: context())
        XCTAssertEqual(unknown.outcome, .unknownSkill)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
