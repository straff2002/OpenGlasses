import XCTest
@testable import OpenGlasses

/// Plan CB P2 — the `look_closely` tool against fakes: ordering, timeout, and every degrade path.
@MainActor
final class LookCloselyToolTests: XCTestCase {

    /// Records the interleaving of capture and injection — the ordering contract is the test.
    private final class Recorder {
        var events: [String] = []
    }

    @MainActor
    private final class FakeInjector: LiveSessionInjecting {
        let recorder: Recorder
        var canInject: Bool = true
        init(recorder: Recorder) { self.recorder = recorder }
        func injectSharpImage(jpegData: Data) {
            recorder.events.append("inject(\(jpegData.count)B)")
        }
        func injectText(_ text: String, completeTurn: Bool) {
            recorder.events.append("text(completeTurn: \(completeTurn))")
        }
    }

    private func makeTool(
        recorder: Recorder,
        injector: FakeInjector?,
        posture: PowerPosture = .normal,
        capture: @escaping () async throws -> Data = { Data(count: 1024) }
    ) -> LookCloselyTool {
        LookCloselyTool(
            captureSharpFrame: { [recorder] in
                let data = try await capture()
                recorder.events.append("capture(\(data.count)B)")
                return data
            },
            injectorProvider: { injector },
            posture: { posture })
    }

    func testCapturesThenInjectsThenReturnsInstruction() async throws {
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        let tool = makeTool(recorder: recorder, injector: injector)

        let result = try await tool.execute(args: [:])

        // Ordering is the contract: the image must be in the model's view BEFORE the function
        // result telling it to read that image.
        XCTAssertEqual(recorder.events, ["capture(1024B)", "inject(1024B)"])
        XCTAssertEqual(result, LookCloselyPolicy.sharpFrameInstruction)
    }

    func testNoActiveSessionDegradesToVisionToolPointer() async throws {
        let recorder = Recorder()
        let tool = makeTool(recorder: recorder, injector: nil)

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(result.contains("No live video session"))
        XCTAssertTrue(result.contains("vision_assess"), "must point at the tools that carry their own vision")
        XCTAssertTrue(recorder.events.isEmpty, "no session → the camera must not fire")
    }

    func testSessionThatCannotInjectIsTreatedAsAbsent() async throws {
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        injector.canInject = false
        let tool = makeTool(recorder: recorder, injector: injector)

        let result = try await tool.execute(args: [:])
        XCTAssertTrue(result.contains("No live video session"))
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testReservePostureDeclinesWithoutTouchingTheCamera() async throws {
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        let tool = makeTool(recorder: recorder, injector: injector, posture: .reserve)

        let result = try await tool.execute(args: [:])

        XCTAssertTrue(result.contains("power reserve"))
        XCTAssertTrue(recorder.events.isEmpty, "reserve must not spend a full-res capture")
    }

    func testRapidSecondCallIsDeclinedByTheIntervalFloor() async throws {
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        let tool = makeTool(recorder: recorder, injector: injector)

        _ = try await tool.execute(args: [:])
        let second = try await tool.execute(args: [:])

        XCTAssertTrue(second.contains("already in your view"))
        XCTAssertEqual(recorder.events.count, 2, "one capture + one inject — no second capture")
    }

    func testCaptureFailureReturnsHonestDegradeNotThrow() async throws {
        struct CameraDown: LocalizedError { var errorDescription: String? { "lens cap on" } }
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        let tool = makeTool(recorder: recorder, injector: injector,
                            capture: { throw CameraDown() })

        let result = try await tool.execute(args: [:])

        // A thrown error would surface as a bare tool failure; the model needs marching orders.
        XCTAssertTrue(result.contains("Couldn't get a sharp frame"))
        XCTAssertTrue(result.contains("lens cap on"))
        XCTAssertTrue(result.contains("fine detail may be missing"))
        XCTAssertTrue(recorder.events.isEmpty, "failed capture must not inject anything")
    }

    func testHungCaptureTimesOutInsteadOfStrandingTheCall() async throws {
        let recorder = Recorder()
        let injector = FakeInjector(recorder: recorder)
        let tool = makeTool(recorder: recorder, injector: injector,
                            capture: {
                                try await Task.sleep(for: .seconds(30))
                                return Data()
                            })

        let start = ContinuousClock.now
        let result = try await tool.execute(args: [:])
        let elapsed = ContinuousClock.now - start

        XCTAssertTrue(result.contains("did not deliver a photo in time"))
        XCTAssertLessThan(elapsed, .seconds(10),
                          "must give up around the 6 s budget, not wait out the capture")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testDescriptionSaysWhenToReachForIt() {
        let recorder = Recorder()
        let tool = makeTool(recorder: recorder, injector: nil)
        // The description feeds SystemPromptBuilder for both Direct and Live prompts — it must
        // teach the trigger conditions, not just name the tool.
        XCTAssertTrue(tool.description.contains("small print"))
        XCTAssertTrue(tool.description.contains("live session"))
        XCTAssertEqual(tool.name, "look_closely")
    }
}
