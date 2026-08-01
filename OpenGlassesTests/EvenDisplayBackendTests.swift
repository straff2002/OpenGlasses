import Combine
import XCTest
@testable import OpenGlasses

/// Plan AH — the deterministic EVEN G2 stack: packet codec + CRC, fragmentation,
/// renderer mappings, the backend over a packet-recording mock transport, and the
/// decision-branch voice selection that replaces the Neural Band on EVEN.
@MainActor
final class EvenDisplayBackendTests: XCTestCase {

    // MARK: - CRC

    func testCRC16CCITTStandardVector() {
        // CCITT-FALSE published check value: "123456789" → 0x29B1. Fixture built from the
        // published algorithm parameters, not copied from community capture logs.
        XCTAssertEqual(CRC16CCITT.compute(Array("123456789".utf8)), 0x29B1)
        XCTAssertEqual(CRC16CCITT.compute([]), 0xFFFF)
    }

    // MARK: - Packet codec

    func testPacketRoundTrip() {
        let packet = EvenPacket(type: .command, sequence: 7, service: 0x0102,
                                payload: Array("hello".utf8))
        let encoded = packet.encoded()
        XCTAssertEqual(encoded[0], 0xAA)
        XCTAssertEqual(encoded[1], 0x21)
        XCTAssertEqual(encoded[3], UInt8("hello".utf8.count + 2), "len = payload + CRC")
        XCTAssertEqual(EvenPacket.decode(encoded), packet)
    }

    func testCorruptCRCAndFramingRejected() {
        var encoded = EvenPacket(type: .response, sequence: 1, service: 1,
                                 payload: [1, 2, 3]).encoded()
        encoded[encoded.count - 1] ^= 0xFF
        XCTAssertNil(EvenPacket.decode(encoded), "bad CRC must be dropped")
        XCTAssertNil(EvenPacket.decode(Array(encoded.prefix(5))), "truncated frame")
        var wrongHeader = EvenPacket(type: .command, sequence: 1, service: 1, payload: []).encoded()
        wrongHeader[0] = 0xAB
        XCTAssertNil(EvenPacket.decode(wrongHeader))
    }

    func testFragmentationAndReassembly() {
        let payload = (0..<500).map { UInt8(truncatingIfNeeded: $0) }
        let fragments = EvenPacket.fragments(type: .command, sequence: 9, service: 1,
                                             payload: payload)
        XCTAssertEqual(fragments.count, 3, "500 bytes at a 194-byte budget")
        XCTAssertTrue(fragments.allSatisfy { $0.sequence == 9 && $0.packetTotal == 3 })
        XCTAssertEqual(fragments.map(\.packetSerial), [1, 2, 3])
        // Every fragment must survive its own encode/decode.
        for fragment in fragments {
            XCTAssertEqual(EvenPacket.decode(fragment.encoded()), fragment)
        }
        XCTAssertEqual(EvenPacket.reassemble(fragments.shuffled()), payload,
                       "reassembly orders by serial")
        XCTAssertNil(EvenPacket.reassemble(Array(fragments.dropFirst())), "incomplete set")
    }

    func testEmptyPayloadStillFrames() {
        let fragments = EvenPacket.fragments(type: .command, sequence: 1, service: 1, payload: [])
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(EvenPacket.reassemble(fragments), [])
    }

    // MARK: - Renderer

    func testContentRenderTitleIconAndWrap() {
        let frame = EvenScreenRenderer.render(
            title: "Reminder", body: "Standup starts in 10 minutes in the blue meeting room",
            icon: .calendar)
        guard case .lines(let lines) = frame else { return XCTFail() }
        XCTAssertEqual(lines.first, "[▤] Reminder")
        XCTAssertTrue(lines.count >= 2)
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.count <= EvenScreenRenderer.charBudget })
    }

    func testScreenRenderNumbersItemsAndMapsEmphasis() {
        let screen = HUDScreen(title: "Pump check", lines: [
            HUDLine("Close the valve", emphasis: .primary),
            HUDLine("Wear gloves", icon: .hazard, emphasis: .secondary),
            HUDLine("Step 2 of 5", emphasis: .meta),
        ], items: [
            HUDItem(id: "done", label: "Done") {},
            HUDItem(id: "skip", label: "Skip") {},
        ])
        guard case .lines(let lines) = EvenScreenRenderer.render(screen: screen) else { return XCTFail() }
        XCTAssertEqual(lines, [
            "Pump check",
            "Close the valve",
            "  [!] Wear gloves",
            "· Step 2 of 5",
            "1. Done",
            "2. Skip",
        ])
    }

    func testAllTenIconsHaveAMonoDecision() {
        // `.none` maps to nothing; every other semantic icon maps to a glyph.
        for icon in [HUDIcon.info, .success, .warning, .error, .navigation, .hazard,
                     .calendar, .location, .reminder, .message] {
            XCTAssertNotNil(EvenScreenRenderer.iconGlyph(icon), "\(icon)")
        }
        XCTAssertNil(EvenScreenRenderer.iconGlyph(.none))
    }

    func testClearFrameIsEmpty() {
        XCTAssertEqual(EvenScreenRenderer.clearFrame(), .lines([]))
        XCTAssertEqual(EvenScreenRenderer.clearFrame().payloadBytes, [])
    }

    func testWrapIsHeadBiased() {
        let lines = EvenScreenRenderer.wrap("one two three four five six", width: 10, maxLines: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "one two")
        XCTAssertTrue(lines[1].hasPrefix("three"), "head of the message survives, tail is cut")
    }

    // MARK: - Backend over a mock transport

    private final class MockTransport: EvenTransporting {
        var isConnected = false
        var sent: [[UInt8]] = []
        var onEvent: (([UInt8]) -> Void)?
        var onDisconnect: ((Error?) -> Void)?
        func connect() async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func sendRenderPacket(_ bytes: [UInt8]) async throws { sent.append(bytes) }
    }

    func testScreenSendProducesDecodablePacketStream() async throws {
        let transport = MockTransport()
        let backend = EvenDisplayBackend(transport: transport)
        let screen = HUDScreen(title: "Menu", items: [
            HUDItem(id: "a", label: "First") {},
            HUDItem(id: "b", label: "Second") {},
        ])
        try await backend.send(screen: screen)

        XCTAssertTrue(transport.isConnected, "lazy connect on first render")
        let packets = transport.sent.compactMap { EvenPacket.decode($0) }
        XCTAssertEqual(packets.count, transport.sent.count, "every packet decodes")
        let payload = EvenPacket.reassemble(packets)
        XCTAssertNotNil(payload)
        let text = String(decoding: payload ?? [], as: UTF8.self)
        XCTAssertEqual(text, "Menu\n1. First\n2. Second")
    }

    func testSelectionRoundTripAndBounds() async throws {
        let transport = MockTransport()
        let backend = EvenDisplayBackend(transport: transport)
        var selected: [String] = []
        backend.onItemSelected = { selected.append($0) }
        let screen = HUDScreen(items: [
            HUDItem(id: "low", label: "Below 20 psi") {},
            HUDItem(id: "ok", label: "20 psi or above") {},
        ])
        try await backend.send(screen: screen)

        backend.selectItem(index: 2)
        backend.selectItem(index: 0)   // out of range — 1-based
        backend.selectItem(index: 3)   // out of range
        XCTAssertEqual(selected, ["ok"])

        // Ambient content clears the selectable set.
        try await backend.showContent(title: nil, body: "hello", icon: .none)
        backend.selectItem(index: 1)
        XCTAssertEqual(selected, ["ok"])
    }

    func testClearSendsEmptyFrame() async throws {
        let transport = MockTransport()
        let backend = EvenDisplayBackend(transport: transport)
        try await backend.clear()
        let packets = transport.sent.compactMap { EvenPacket.decode($0) }
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].payload, [])
    }

    // MARK: - Service routing (regression)

    func testServiceSinkStillCapturesAboveTheBackend() async {
        let wasEnabled = Config.glassesDisplayEnabled
        Config.setGlassesDisplayEnabled(true)
        defer { Config.setGlassesDisplayEnabled(wasEnabled) }
        let service = GlassesDisplayService()
        service.testCapabilityOverride = true
        var frames: [GlassesDisplayService.HUDFrame] = []
        service.testRenderSink = { frames.append($0) }
        service.showText("hello world")
        // Async suspension lets the render queue's MainActor task drain.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(frames, [.content(body: "hello world", title: nil, icon: .none)])
    }

    // MARK: - Decision-branch voice selection (Plan AH input gap)

    private final class FakeBranchSource: HUDTaskSource {
        let title = "Pump check"
        var current: HUDStep? = HUDStep(index: 0, total: nil, title: "Check pressure")
        var next: HUDStep? { nil }
        let choices = [HUDChoice(id: "low", label: "Below 20 psi"),
                       HUDChoice(id: "ok", label: "20 psi or above")]
        var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        var chosen: [String] = []
        var completed = 0
        func complete() async { completed += 1 }
        func skip() async {}
        func back() async {}
        func choose(_ id: String) async { chosen.append(id) }
    }

    func testSpokenBranchLabelSelectsChoice() async {
        let display = GlassesDisplayService()
        display.testCapabilityOverride = true
        display.testRenderSink = { _ in }
        let router = HUDRouter(display: display)
        let source = FakeBranchSource()
        router.startTask(source)

        let exact = await router.handleVoiceCommand("below 20 psi")
        XCTAssertTrue(exact, "exact label")
        XCTAssertEqual(source.chosen, ["low"])
        let substring = await router.handleVoiceCommand("or above")
        XCTAssertTrue(substring, "unique substring")
        XCTAssertEqual(source.chosen, ["low", "ok"])
        // Ambiguous ("psi" hits both) and unrelated speech are not consumed.
        let ambiguous = await router.handleVoiceCommand("psi")
        XCTAssertFalse(ambiguous)
        let unrelated = await router.handleVoiceCommand("what's the weather")
        XCTAssertFalse(unrelated)
        // The linear verbs still work on a branching card.
        let done = await router.handleVoiceCommand("done")
        XCTAssertTrue(done)
        XCTAssertEqual(source.completed, 1)
    }
}
