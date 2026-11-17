import XCTest
@testable import OpenGlasses

/// `build_addon` is declared only while building is allowed, says what it does honestly, and
/// refuses when it isn't wired.
@MainActor
final class BuildAddOnToolTests: XCTestCase {

    func testTheAvailabilityRule() {
        typealias A = AddOnAuthoringAvailability
        XCTAssertEqual(A.unavailable(.init()), .agentModeOff)
        XCTAssertNil(A.unavailable(.init(agentModeEnabled: true)))
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, hipaaMode: true)), .medicalCompliance)
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, localOnly: true)), .medicalCompliance)
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, addOnsEnabled: false)), .addOnsOff)
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, organisationForbidsSelfBuilt: true)), .organisationForbids)
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, policy: AddOnPolicy(ceiling: .signedOnly))),
                       .policy(.communityNotAllowed))
        XCTAssertEqual(A.unavailable(.init(agentModeEnabled: true, policy: AddOnPolicy(ceiling: .addOnsDisabled))),
                       .policy(.addOnsDisabled))
    }

    func testThreeSessionsACalendarDay() {
        let calendar = Calendar(identifier: .gregorian)
        let morning = Date(timeIntervalSince1970: 1_794_000_000)
        let starts = [morning, morning.addingTimeInterval(60), morning.addingTimeInterval(120)]
        XCTAssertTrue(AddOnAuthoringAvailability.allowsAnotherSession(starts: Array(starts.prefix(2)), now: morning,
                                                                    calendar: calendar))
        XCTAssertFalse(AddOnAuthoringAvailability.allowsAnotherSession(starts: starts, now: morning, calendar: calendar))
        XCTAssertTrue(AddOnAuthoringAvailability.allowsAnotherSession(starts: starts, now: morning.addingTimeInterval(86_400),
                                                                    calendar: calendar))
    }

    func testDeclaredOnlyWhenAllowedAndWired() {
        var tool = BuildAddOnTool()
        tool.availability = { nil }
        XCTAssertFalse(tool.isOfferedNow, "without the running service it is never offered")
        let registry = NativeToolRegistry(locationService: LocationService())
        XCTAssertFalse(registry.toolNames.contains(BuildAddOnTool.toolName))
        XCTAssertNil(registry.tool(named: BuildAddOnTool.toolName))

        tool.availability = { .agentModeOff }
        XCTAssertFalse(tool.isOfferedNow)
    }

    func testItsDescriptionSaysTheWearerReviewsItOnThePhone() {
        let description = BuildAddOnTool().description.lowercased()
        XCTAssertTrue(description.contains("never installs anything silently"))
        XCTAssertTrue(description.contains("approves it on the phone"))
        XCTAssertFalse(description.contains("beta"))
    }

    func testAnUnwiredToolRefuses() async throws {
        let text = try await BuildAddOnTool().execute(args: ["action": "start", "goal": "tide times"])
        XCTAssertEqual(text, "Building add-ons isn't available right now.")
    }

    func testItIsANetworkToolUnderEveryPolicy() {
        XCTAssertEqual(OfflineToolPolicy.table[BuildAddOnTool.toolName], .needsNetwork)
        XCTAssertTrue(Config.hipaaDisabledTools.contains(BuildAddOnTool.toolName))
    }
}
