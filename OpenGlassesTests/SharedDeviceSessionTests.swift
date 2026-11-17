import XCTest
@testable import OpenGlasses

/// The camera and the lens share one `DeviceSession` per pair (`DeviceSessionCoordinator`). Each
/// used to create its own, and the SDK refuses a second session for a device: a Ray-Ban Display
/// report (build 705) shows `sessionAlreadyExists` on the lens for as long as the camera held the
/// glasses. Read from the sources, because the real sessions cannot be made in a headless test.
final class SharedDeviceSessionTests: XCTestCase {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("OpenGlasses/Sources")

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Only the coordinator creates a session. Comments are skipped.
    func testOnlyTheCoordinatorCreatesASession() throws {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "DeviceSessionCoordinator.swift" else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains(".createSession(deviceSelector:") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "borrow from DeviceSessionCoordinator.shared instead")
    }

    func testTheCameraBorrowsAndHandsBack() throws {
        let camera = try text("Services/Camera/MetaCameraBackend.swift")
        XCTAssertTrue(camera.contains("DeviceSessionCoordinator.shared.acquire(\n                .camera, deviceId: binding.deviceId)"))
        XCTAssertTrue(camera.contains("let stoppedShared = DeviceSessionCoordinator.shared.release(.camera)"))
        XCTAssertFalse(camera.contains("session.stop()\n            // The replacement boundary"),
                       "the camera's reset hands the session back rather than stopping it")
        XCTAssertTrue(camera.contains("if deviceSession.state != .starting { try deviceSession.start() }"))
    }

    func testTheLensBorrowsAndHandsBack() throws {
        let display = try text("Services/Display/MetaDisplayBackend.swift")
        XCTAssertTrue(display.contains("DeviceSessionCoordinator.shared.acquire(.display)"))
        XCTAssertTrue(display.contains("func stop() { DeviceSessionCoordinator.shared.release(.display) }"))
        XCTAssertTrue(display.contains("func relinquish() { DeviceSessionCoordinator.shared.release(.display) }"))
        XCTAssertTrue(display.contains("if stopping { session?.stop() } else { session?.relinquish() }"),
                      "a session that died under the lens is still handed back")
        XCTAssertTrue(display.contains("if session.sessionState != .starting { try session.start() }"))
    }

    /// A photo can stop the Display under the live session; the lens is drawn again, not dismissed.
    func testADisplayStoppedUnderTheSessionIsRedrawn() throws {
        let display = try text("Services/Display/MetaDisplayBackend.swift")
        XCTAssertTrue(display.contains("watchDisplay(display)\n        display.start()"),
                      "the display is watched before it is started")
        let service = try text("Services/GlassesDisplayService.swift")
        XCTAssertTrue(service.contains("meta.onDisplayStoppedUnderSession = { [weak self] in self?.lensInterrupted() }"))
    }

    func testTheSharedSessionBindsToTheConnectedPair() throws {
        let app = try text("App/OpenGlassesApp.swift")
        XCTAssertTrue(app.contains("DeviceSessionCoordinator.shared.readConnectedDevice = { [weak self] in"))
    }
}
