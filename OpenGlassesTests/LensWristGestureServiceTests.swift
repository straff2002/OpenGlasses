#if DAT_EXPERIMENTAL
import XCTest
@testable import OpenGlasses

/// The page view's wrist gestures (Plan NB §6, P2), with a fake channel behind
/// `WristMotionSource`. Compiled only in a flagged project. Never touches `Wearables.shared`.
@MainActor
final class LensWristGestureServiceTests: XCTestCase {

    @MainActor
    final class FakeMotionChannel: MotionChannel {
        let handlers: MotionChannelHandlers
        var stopCount = 0
        var state: MotionChannelState
        init(handlers: MotionChannelHandlers, state: MotionChannelState) {
            self.handlers = handlers
            self.state = state
        }
        func stop() { stopCount += 1 }
    }

    @MainActor
    final class FakeMotionSource: WristMotionSource {
        var opened: [(deviceId: String, channel: FakeMotionChannel)] = []
        var failure: MotionChannelFailure?
        var holds = false
        var hold: CheckedContinuation<Void, Never>?
        var stateAtOpen: MotionChannelState = .started

        func open(deviceId: String, handlers: MotionChannelHandlers) async throws -> MotionChannel {
            if holds { await withCheckedContinuation { hold = $0 } }
            if let failure { throw failure }
            let channel = FakeMotionChannel(handlers: handlers, state: stateAtOpen)
            opened.append((deviceId, channel))
            return channel
        }

        var last: FakeMotionChannel? { opened.last?.channel }
    }

    private final class Clock {
        var now = ContinuousClock.now
    }

    private lazy var source = FakeMotionSource()
    private var switches = LensWristGestures.Switches(twist: true, pan: false)
    private var rungs: [TwistRung] = []
    private var steps: [LensPageViewport.Step] = []
    private var clutch: [String] = []
    private var listened = 0
    private var failures = 0
    private let clock = Clock()

    private func service() -> LensWristGestureService {
        LensWristGestureService(
            source: source,
            switches: { [unowned self] in self.switches },
            sink: .init(twist: { [unowned self] in self.rungs.append($0) },
                        pan: { [unowned self] in self.steps.append($0) },
                        clutchOpened: { [unowned self] in self.clutch.append("open") },
                        clutchClosed: { [unowned self] in self.clutch.append("closed") },
                        listening: { [unowned self] in self.listened += 1 },
                        failed: { [unowned self] in self.failures += 1 }),
            clock: { [unowned self] in self.clock.now })
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private let ms: Int64 = 1_000_000
    private let burst = GlassesInput(kind: .drag(.down), origin: .neuralBandDrag)

    private func twist(_ t: Int64, _ degrees: Double) -> WristSample {
        WristSample(timestampNs: t * ms, orientation: WristQuaternion(axis: .forearm, angle: WristTwist.radians(degrees)))
    }

    func testWhichViewsEachGestureCanChange() {
        let twist = LensWristGestures.Switches(twist: true, pan: false)
        let pan = LensWristGestures.Switches(twist: false, pan: true)
        let off = LensWristGestures.Switches(twist: false, pan: false)
        XCTAssertTrue(LensWristGestureService.canChange(.whole, switches: twist))
        XCTAssertFalse(LensWristGestureService.canChange(.whole, switches: pan), "the whole page does not pan")
        for view in [HUDPageViewState.View.closeUp, .zoomed] {
            XCTAssertTrue(LensWristGestureService.canChange(view, switches: twist))
            XCTAssertTrue(LensWristGestureService.canChange(view, switches: pan))
            XCTAssertFalse(LensWristGestureService.canChange(view, switches: off))
        }
        for view in [HUDPageViewState.View.rows, .reading] {
            XCTAssertFalse(LensWristGestureService.canChange(view, switches: .init(twist: true, pan: true)))
        }
        XCTAssertFalse(LensWristGestureService.canChange(nil, switches: twist))
    }

    func testMotionIsOpenOnlyWhileAViewItCanChangeIsUpWithALink() async {
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        await settle()
        XCTAssertTrue(source.opened.isEmpty, "no page view")
        wrist.update(view: .whole)
        await settle()
        XCTAssertEqual(source.opened.map(\.deviceId), ["pair-1"])
        XCTAssertEqual(listened, 1)
        wrist.update(view: .rows)
        XCTAssertFalse(wrist.isListening, "rows take no rung")
        XCTAssertEqual(source.last?.stopCount, 1)
        wrist.update(view: .zoomed)
        await settle()
        XCTAssertEqual(source.opened.count, 2)
        wrist.update(connectedDeviceIds: [])
        XCTAssertFalse(wrist.isListening)
    }

    func testBothSwitchesOffOpenNothingAndTheDragStreamFollowsThem() async {
        switches = .init(twist: false, pan: false)
        let wrist = service()
        XCTAssertFalse(wrist.wantsDrag)
        wrist.update(connectedDeviceIds: ["pair-1"])
        wrist.update(view: .zoomed)
        await settle()
        XCTAssertTrue(source.opened.isEmpty)
        switches = .init(twist: false, pan: true)
        XCTAssertTrue(wrist.wantsDrag)
        wrist.refresh()
        await settle()
        XCTAssertEqual(source.opened.count, 1, "the pan's switch alone opens it")
    }

    func testAClutchedTwistSendsRungsAndClosesWithItsSelect() async {
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        wrist.update(view: .zoomed)
        await settle()
        let handlers = try! XCTUnwrap(source.last?.handlers)
        handlers.onSample(twist(0, 0))
        handlers.onSample(twist(200, 40))
        XCTAssertEqual(rungs, [], "no clutch: a wrist turns all the time")
        wrist.handleBandInput(burst)
        XCTAssertEqual(clutch, ["open"])
        for (t, d) in [(0, 0.0), (200, 0), (240, 25), (280, 45)] { handlers.onSample(twist(Int64(t) + 1000, d)) }
        XCTAssertEqual(rungs, [.zoomIn, .zoomIn])
        wrist.handleBandInput(GlassesInput(kind: .select, origin: .neuralBand))
        XCTAssertEqual(clutch, ["open", "closed"])
        handlers.onSample(twist(1400, 90))
        XCTAssertEqual(rungs.count, 2)
    }

    func testTheArmPansWhenItsSwitchIsOn() async {
        switches = .init(twist: false, pan: true)
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        wrist.update(view: .closeUp)
        await settle()
        let handlers = try! XCTUnwrap(source.last?.handlers)
        wrist.handleBandInput(burst)
        let yaw = { (t: Int64, d: Double) in
            WristSample(timestampNs: t * self.ms, orientation: WristQuaternion(axis: .up, angle: WristTwist.radians(d)))
        }
        for (t, d) in [(0, 0.0), (200, 0), (240, 13)] { handlers.onSample(yaw(Int64(t), d)) }
        XCTAssertEqual(steps, [.left])
        XCTAssertEqual(rungs, [])
    }

    func testAFailureIsNotRetriedWhileThePageViewStaysUp() async {
        source.failure = .sensorUnavailable
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        wrist.update(view: .whole)
        await settle()
        XCTAssertEqual(failures, 1)
        source.failure = nil
        wrist.update(view: .zoomed)
        await settle()
        XCTAssertTrue(source.opened.isEmpty, "held off while the page view stays up")
        wrist.update(view: nil)
        wrist.update(view: .whole)
        await settle()
        XCTAssertEqual(source.opened.count, 1, "the next page view asks again")
        source.last?.handlers.onFailure(.deviceDisconnected)
        XCTAssertFalse(wrist.isListening)
        XCTAssertEqual(failures, 2)
    }

    func testStoppingMidClutchClosesItForThePressGuard() async {
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        wrist.update(view: .zoomed)
        await settle()
        wrist.handleBandInput(burst)
        wrist.update(view: .reading)
        XCTAssertEqual(clutch, ["open", "closed"])
        wrist.handleBandInput(burst)
        XCTAssertEqual(clutch, ["open", "closed"], "no channel: the band's inputs open nothing")
    }

    func testTheProbesComeFirst() async {
        let wrist = service()
        wrist.update(connectedDeviceIds: ["pair-1"])
        source.holds = true
        wrist.update(view: .zoomed)
        await settle()
        XCTAssertTrue(wrist.isListening)
        let yielded = Task { @MainActor in await wrist.yield() }
        await settle()
        source.hold?.resume()
        await yielded.value
        XCTAssertEqual(source.last?.stopCount, 1, "what the open added is taken off before the probe adds it")
        source.holds = false
        wrist.update(probeRunning: true)
        await settle()
        XCTAssertEqual(source.opened.count, 1, "nothing opens while a probe runs")
        wrist.update(probeRunning: false)
        await settle()
        XCTAssertEqual(source.opened.count, 2)
    }
}
#endif
