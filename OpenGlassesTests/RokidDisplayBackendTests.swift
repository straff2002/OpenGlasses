import Combine
import XCTest
@testable import OpenGlasses

/// Plan AH (Rokid) — the deterministic stack: command model + JSON codec, renderer
/// mappings, the backend over a command-recording mock transport, and the decision-branch
/// voice selection (shared with the EVEN path). The Caps framing / GATT UUIDs are
/// hardware-gated and deliberately out of scope for this suite.
@MainActor
final class RokidDisplayBackendTests: XCTestCase {

    // MARK: - Command model & codec

    func testTTSCommandUsesPublishedSchema() {
        let command = RokidCommand.tts("你好")
        XCTAssertEqual(command.cmd, "Sys")
        XCTAssertEqual(command.key, "Tts_SendPlayTts")
        XCTAssertTrue(command.param.contains("\"content\""), "documented param key")
        XCTAssertTrue(command.param.contains("你好"))
        XCTAssertEqual(RokidWireCodec.decode(command.encoded()), command, "round-trips")
    }

    func testNotificationCommandRoundTrip() {
        let command = RokidCommand.notification(title: "Reminder", text: "Standup soon", icon: "calendar")
        XCTAssertEqual(command.cmd, "Ntf")
        let decoded = RokidWireCodec.decode(command.encoded())
        XCTAssertEqual(decoded, command)
    }

    func testClearCustomViewCommandIsStable() {
        let command = RokidCommand.clearCustomView()
        XCTAssertEqual(command.cmd, "Custom_View")
        XCTAssertEqual(command.key, "Custom_View_Clear")
        XCTAssertEqual(command.param, "{}")
    }

    // MARK: - Renderer

    func testContentRendersNotificationCard() {
        let commands = RokidScreenRenderer.renderContent(
            title: "Reminder", body: "Standup starts soon", icon: .calendar)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].cmd, "Ntf")
        XCTAssertTrue(commands[0].param.contains("calendar"), "icon name is carried")
        XCTAssertTrue(commands[0].param.contains("Standup starts soon"))
    }

    func testScreenParamCarriesTitleLinesAndNumberedItems() {
        let screen = HUDScreen(title: "Pump check", lines: [
            HUDLine("Close the valve", emphasis: .primary),
            HUDLine("Wear gloves", icon: .hazard, emphasis: .secondary),
        ], items: [
            HUDItem(id: "done", label: "Done") {},
            HUDItem(id: "skip", label: "Skip") {},
        ])
        let param = RokidScreenRenderer.screenParam(screen)
        XCTAssertEqual(param["title"] as? String, "Pump check")
        let lines = param["lines"] as? [[String: Any]]
        XCTAssertEqual(lines?.count, 2)
        XCTAssertEqual(lines?[1]["icon"] as? String, "hazard")
        XCTAssertEqual(lines?[1]["emphasis"] as? String, "secondary")
        let items = param["items"] as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0]["id"] as? String, "done")
        XCTAssertEqual(items?[0]["index"] as? Int, 1)
    }

    func testAllTenIconsHaveASemanticName() {
        for icon in [HUDIcon.info, .success, .warning, .error, .navigation, .hazard,
                     .calendar, .location, .reminder, .message] {
            XCTAssertFalse(RokidScreenRenderer.iconName(icon).isEmpty, "\(icon)")
        }
        XCTAssertEqual(RokidScreenRenderer.iconName(.none), "none")
    }

    // MARK: - Backend over a mock transport

    private final class MockTransport: RokidTransporting {
        var isConnected = false
        var sent: [[UInt8]] = []
        var onEvent: (([UInt8]) -> Void)?
        var onDisconnect: ((Error?) -> Void)?
        func connect() async throws { isConnected = true }
        func disconnect() { isConnected = false }
        func send(_ bytes: [UInt8]) async throws { sent.append(bytes) }
    }

    func testScreenSendProducesDecodableCommandStream() async throws {
        let transport = MockTransport()
        let backend = RokidDisplayBackend(transport: transport)
        let screen = HUDScreen(title: "Menu", items: [
            HUDItem(id: "a", label: "First") {},
            HUDItem(id: "b", label: "Second") {},
        ])
        try await backend.send(screen: screen)

        XCTAssertTrue(transport.isConnected, "lazy connect on first render")
        let commands = transport.sent.compactMap { RokidWireCodec.decode($0) }
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].cmd, "Custom_View")
        // The param JSON text itself must be valid and carry the item ids.
        guard let paramObject = try? JSONSerialization.jsonObject(
            with: Data(commands[0].param.utf8)) as? [String: Any],
            let items = paramObject["items"] as? [[String: Any]] else {
            return XCTFail("param must be a valid JSON object")
        }
        XCTAssertEqual(items.map { $0["id"] as? String }, ["a", "b"])
    }

    func testSelectionRoundTripAndBounds() async throws {
        let transport = MockTransport()
        let backend = RokidDisplayBackend(transport: transport)
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

    func testClearSendsClearCommand() async throws {
        let transport = MockTransport()
        let backend = RokidDisplayBackend(transport: transport)
        try await backend.clear()
        let commands = transport.sent.compactMap { RokidWireCodec.decode($0) }
        XCTAssertEqual(commands, [.clearCustomView()])
    }
}
