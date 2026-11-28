#if DAT_EXPERIMENTAL
import XCTest
@testable import OpenGlasses

/// The page view's band channel (Plan MU §7, P6), with a fake channel behind `InputsSource`.
/// Compiled only in a flagged project. Never touches `Wearables.shared`.
@MainActor
final class LensBandNavServiceTests: XCTestCase {

    @MainActor
    private final class FakeChannel: InputsChannel {
        let handlers: InputsChannelHandlers
        var stopCount = 0
        var state: InputsProbeState
        init(handlers: InputsChannelHandlers, state: InputsProbeState) {
            self.handlers = handlers
            self.state = state
        }
        func stop() { stopCount += 1 }
    }

    @MainActor
    private final class FakeSource: InputsSource {
        var opened: [(deviceId: String, channel: FakeChannel)] = []
        var failure: InputsProbeFailure?
        var holds = false
        var hold: CheckedContinuation<Void, Never>?
        var stateAtOpen: InputsProbeState = .active

        func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel {
            if holds { await withCheckedContinuation { hold = $0 } }
            if let failure { throw failure }
            let channel = FakeChannel(handlers: handlers, state: stateAtOpen)
            opened.append((deviceId, channel))
            return channel
        }

        var last: FakeChannel? { opened.last?.channel }
    }

    private struct ThrowingSource: InputsSource {
        let error: Error
        func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel { throw error }
    }

    private lazy var source = FakeSource()
    private var enabled = true
    private var inputs: [GlassesInputKind] = []
    private var listened = 0
    private var failures = 0
    private var failureCases: [InputsProbeFailure] = []
    private var ends: [String] = []

    private func service() -> LensBandNavService {
        LensBandNavService(source: source, isEnabled: { [unowned self] in self.enabled },
                           onInput: { [unowned self] in self.inputs.append($0.kind) },
                           onListening: { [unowned self] in self.listened += 1 },
                           onFailed: { [unowned self] in self.failures += 1; self.failureCases.append($0) },
                           onEnded: { [unowned self] in self.ends.append($0) })
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testTheSDKConfigurationIsTheBandsSwipesWithBackLeftToMeta() {
        XCTAssertEqual(LensBandNavConfiguration.origins, LensBandNavPolicy.origins)
        XCTAssertEqual(LensBandNavConfiguration.origins, [.neuralBand])
        XCTAssertFalse(LensBandNavConfiguration.consumesBack)
        XCTAssertEqual(InputsPurpose.lensBandNav.configuration.sources, LensBandNavConfiguration.sdk.sources)
        XCTAssertEqual(InputsPurpose.probe.configuration.sources, InputsProbeConfiguration.sdk.sources)
        // Plan NB §6: with a wrist gesture on, the drag stream too; Back still Meta's.
        XCTAssertEqual(LensBandNavConfiguration.originsWithDrag, LensBandNavPolicy.originsWithDrag)
        XCTAssertEqual(InputsPurpose.lensBandNavWithDrag.configuration.sources, LensBandNavConfiguration.withDrag.sources)
        XCTAssertFalse(LensBandNavConfiguration.withDrag.consumeBack)
    }

    func testReopenAsksForTheChannelAgain() async {
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        band.update(viewOnLens: true)
        await settle()
        XCTAssertEqual(source.opened.count, 1)
        band.reopen()
        await settle()
        XCTAssertEqual(source.opened.count, 2, "a wrist switch changed: asked for with the new configuration")
        XCTAssertEqual(source.opened[0].channel.stopCount, 1)
        source.last?.handlers.onInput(GlassesInput(kind: .drag(.down), origin: .neuralBandDrag))
        XCTAssertEqual(inputs, [.drag(.down)], "the whole input reaches the wiring, its source too")
    }

    func testItListensOnlyWhileThePageViewIsOnTheLensWithALink() async {
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        await settle()
        XCTAssertTrue(source.opened.isEmpty, "no page view: nothing opened")
        band.update(viewOnLens: true)
        await settle()
        XCTAssertEqual(source.opened.map(\.deviceId), ["pair-1"])
        XCTAssertEqual(listened, 1)
        source.last?.handlers.onInput(GlassesInput(kind: .nav(.right), origin: .neuralBand))
        source.last?.handlers.onInput(GlassesInput(kind: .nav(.down), origin: .neuralBand))
        XCTAssertEqual(inputs, [.nav(.right), .nav(.down)], "every input goes to the page view, which decides")
        band.update(viewOnLens: false)
        XCTAssertEqual(source.last?.stopCount, 1)
        XCTAssertFalse(band.isListening)
        source.opened[0].channel.handlers.onInput(GlassesInput(kind: .nav(.left), origin: .neuralBand))
        XCTAssertEqual(inputs.count, 2, "a stopped channel's late input is ignored")
    }

    func testTheSwitchAndTheLinkCloseIt() async {
        let band = service()
        band.update(viewOnLens: true)
        band.update(connectedDeviceIds: ["pair-1"])
        await settle()
        XCTAssertTrue(band.isListening)
        enabled = false
        band.refresh()
        XCTAssertFalse(band.isListening)
        XCTAssertEqual(source.last?.stopCount, 1)
        enabled = true
        band.refresh()
        await settle()
        XCTAssertEqual(source.opened.count, 2)
        band.update(connectedDeviceIds: [])
        XCTAssertFalse(band.isListening)
    }

    func testAFailureIsNotRetriedForTheSameView() async {
        source.failure = .capabilityUnavailable
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        band.update(viewOnLens: true)
        await settle()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(failureCases, [.capabilityUnavailable], "the case goes to the report (build 799)")
        source.failure = nil
        band.refresh()
        await settle()
        XCTAssertTrue(source.opened.isEmpty, "held off until the view closes")
        band.update(viewOnLens: false)
        band.update(viewOnLens: true)
        await settle()
        XCTAssertEqual(source.opened.count, 1, "the next view asks again")
        source.last?.handlers.onInputsEnded()
        XCTAssertFalse(band.isListening)
        XCTAssertEqual(ends, ["inputsEnded"])
        band.refresh()
        await settle()
        XCTAssertEqual(source.opened.count, 1, "an ended channel is not reopened for the same view")
    }

    func testAnErrorThatIsNotTheChannelsOwnIsReportedAsUnknown() async {
        struct Other: Error {}
        let band = LensBandNavService(source: ThrowingSource(error: Other()), isEnabled: { true }, onInput: { _ in },
                                      onFailed: { [unowned self] in self.failureCases.append($0) })
        band.update(connectedDeviceIds: ["pair-1"])
        band.update(viewOnLens: true)
        await settle()
        XCTAssertEqual(failureCases, [.unknown])
    }

    func testAFailureOnAnOpenChannelCarriesItsCase() async {
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        band.update(viewOnLens: true)
        await settle()
        source.last?.handlers.onFailure(.activationTimeout)
        XCTAssertEqual(failureCases, [.activationTimeout])
        XCTAssertFalse(band.isListening)
    }

    func testTheSessionEndingIsReportedAsSuch() async {
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        band.update(viewOnLens: true)
        await settle()
        source.last?.handlers.onEnded()
        XCTAssertEqual(ends, ["sessionEnded"])
    }

    func testTheProbeComesFirst() async {
        let band = service()
        band.update(connectedDeviceIds: ["pair-1"])
        source.holds = true
        band.update(viewOnLens: true)
        await settle()
        XCTAssertTrue(band.isListening, "an open is in flight")
        let yielded = Task { @MainActor in await band.yield() }
        await settle()
        source.hold?.resume()
        await yielded.value
        XCTAssertEqual(source.last?.stopCount, 1, "what the open added is taken off before the probe adds it")
        source.holds = false
        band.update(probeRunning: true)
        band.refresh()
        await settle()
        XCTAssertEqual(source.opened.count, 1, "nothing opens while the probe runs")
        band.update(probeRunning: false)
        await settle()
        XCTAssertEqual(source.opened.count, 2, "listening again once the run is over")
    }
}
#endif
