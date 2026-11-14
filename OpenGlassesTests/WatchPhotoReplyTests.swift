import XCTest
@testable import OpenGlasses

/// Plan LT §3 — a photo command from the watch reports its own result: an answer it made, or an
/// error line, never the previous answer; and it never opens a phone camera nobody is looking at.
final class WatchPhotoReplyTests: XCTestCase {

    private static let failures: [PhotoTurnResult] = [
        .cannotSee, .glassesNotConnected, .phoneCameraOpened, .captureFailed, .modelFailed, .busy,
    ]

    func testAnAnswerIsSentAsTheResponse() {
        let reply = WatchPhotoReply.dictionary(for: .answered("A red bicycle."))
        XCTAssertEqual(reply["status"] as? String, "completed")
        XCTAssertEqual(reply["response"] as? String, "A red bicycle.")
        XCTAssertNil(reply["error"])
        XCTAssertNil(WatchPhotoReply.line(for: .answered("x")))
    }

    /// The watch shows `response` as the answer. A failure that carried one would put the last
    /// turn's answer on the wrist as if this photo had produced it.
    func testEveryOtherResultIsAnErrorLineWithNoResponse() {
        var lines = Set<String>()
        for result in Self.failures {
            let reply = WatchPhotoReply.dictionary(for: result)
            XCTAssertNil(reply["response"], "\(result) must not carry a response")
            let error = reply["error"] as? String
            XCTAssertFalse(error?.isEmpty ?? true, "\(result) needs a line")
            XCTAssertEqual(error, WatchPhotoReply.line(for: result))
            XCTAssertLessThan(error?.count ?? 0, 60, "a line for the wrist")
            lines.insert(error ?? "")
        }
        XCTAssertEqual(lines.count, Self.failures.count, "each failure says what failed")
        XCTAssertEqual(WatchPhotoReply.line(for: .glassesNotConnected), "Glasses not connected.")
    }

    func testASecondRequestWhileOneRunsIsBusyAtOnce() {
        var gate = WatchPhotoGate()
        XCTAssertTrue(gate.begin(appBusy: false))
        XCTAssertFalse(gate.begin(appBusy: false), "a second request while the first runs")
        gate.end()
        XCTAssertTrue(gate.begin(appBusy: false), "free again once the first has replied")
        gate.end()
        XCTAssertFalse(gate.begin(appBusy: true), "the app is in the middle of another turn")
        XCTAssertFalse(gate.inFlight, "a refused request does not hold the gate")
    }

    // MARK: - The handler, read from source (AppState cannot be stood up headless)

    private func managerCode() throws -> [String] {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/WatchConnectivityManager.swift")
        return try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    /// Every photo turn the watch starts asks for no phone camera and goes through the gate.
    func testWatchPhotoTurnsAskForNoPhoneCamera() throws {
        let code = try managerCode()
        let calls = code.filter { $0.contains("captureAndAnalyzePhoto(") || $0.contains("capturePhotoAndSend(") }
        XCTAssertGreaterThanOrEqual(calls.count, 5, "photo, describe, quick actions and a custom prompt")
        // One `phoneCameraFallback: false` per call (a call may wrap onto a second line).
        XCTAssertEqual(code.filter { $0.contains("phoneCameraFallback: false") }.count, calls.count)
        XCTAssertEqual(code.filter { $0.contains("self.watchPhotoTurn(appState)") }.count, calls.count,
                       "every photo turn replies through the gate and WatchPhotoReply")
    }

    /// The only command still answering with `lastResponse` is dictation, which checks for a turn
    /// in flight first; no photo command does.
    func testNoPhotoCommandRepliesWithTheLastResponse() throws {
        let code = try managerCode()
        let stale = code.filter { $0.contains("\"response\": appState.lastResponse") }
        XCTAssertEqual(stale.count, 1, "only the dictation reply: \(stale)")
    }
}
