import XCTest
@testable import OpenGlasses

/// Plan GE P2 — what the phone can answer with no model at all.
final class OfflineKeywordRouterTests: XCTestCase {

    private func route(_ text: String) -> OfflineKeywordRouter.Route? { OfflineKeywordRouter.route(text) }

    func testTimers() {
        XCTAssertEqual(route("Set a timer for 5 minutes")?.seconds, 300)
        XCTAssertEqual(route("timer for ninety seconds")?.seconds, 90)
        XCTAssertEqual(route("start a 10 minute timer")?.seconds, 600)
        XCTAssertEqual(route("set a timer for an hour")?.seconds, 3600)
        XCTAssertEqual(route("set a timer for half an hour")?.seconds, 1800)
        XCTAssertEqual(route("timer for forty five minutes")?.seconds, 2700)
        XCTAssertEqual(route("set a timer for 5 minutes")?.toolName, "set_timer")
        XCTAssertNil(route("how does a kitchen timer work")?.seconds, "no duration, no timer")
    }

    func testRememberThatKeepsTheWearersWording() {
        let r = route("Remember that the gate code is 4412.")
        XCTAssertEqual(r?.toolName, "save_note")
        XCTAssertEqual(r?.arguments["content"], "the gate code is 4412")
        XCTAssertEqual(route("make a note that Dave owes me lunch")?.arguments["content"], "Dave owes me lunch")
    }

    func testParking() {
        XCTAssertEqual(route("Where did I park?"), .init(toolName: "parking", arguments: ["action": "where"]))
        XCTAssertEqual(route("where's my car")?.arguments["action"], "where")
        let save = route("I parked on level 2, bay 41")
        XCTAssertEqual(save?.arguments["action"], "save")
        XCTAssertEqual(save?.arguments["details"], "I parked on level 2, bay 41")
        XCTAssertEqual(route("remember that I parked on level 3")?.toolName, "parking",
                       "parking wins over a general note")
    }

    func testMisplacedThings() {
        XCTAssertEqual(route("where are my keys"),
                       .init(toolName: "object_memory", arguments: ["action": "find", "object": "keys"]))
        XCTAssertEqual(route("Where did I leave my wallet?")?.arguments["object"], "wallet")
    }

    func testStepsAndTime() {
        XCTAssertEqual(route("how many steps have I done")?.toolName, "step_count")
        XCTAssertEqual(route("what time is it")?.toolName, "get_datetime")
        XCTAssertEqual(route("What's the date?")?.toolName, "get_datetime")
    }

    func testAnythingElseIsLeftForAModel() {
        XCTAssertNil(route("why is the sky blue"))
        XCTAssertNil(route("summarise what we talked about"))
        XCTAssertNil(route(""))
    }

    /// The router can never reach for the network: every tool it names is a local one.
    func testEveryRouteNamesALocalTool() {
        let samples = ["set a timer for 5 minutes", "remember that x", "where did I park", "I parked here",
                       "where are my keys", "how many steps", "what time is it"]
        for sample in samples {
            let name = route(sample)?.toolName
            XCTAssertNotNil(name, sample)
            XCTAssertEqual(name.flatMap(OfflineToolPolicy.availability(of:)), .local, sample)
        }
    }

    func testTimerArgumentsReachTheToolAsAnInteger() {
        let args = route("set a timer for 2 minutes")?.toolArguments
        XCTAssertEqual(args?["seconds"] as? Int, 120)
    }
}
