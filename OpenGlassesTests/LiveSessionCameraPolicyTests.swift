import XCTest
@testable import OpenGlasses

/// A Discord report: in a live mode the glasses' capture LED stayed on all the time and drained the
/// battery, even for a single "what is this" question. Two causes, two rules
/// (`LiveSessionCameraPolicy`): only a session turns the camera on, never the mode; and Audio-Only
/// Mode keeps it off. The session manager and the app cannot run here, so the last tests read the
/// source.
final class LiveSessionCameraPolicyTests: XCTestCase {

    // MARK: - The rule

    func testAModelThatCanSeeStartsTheCamera() {
        XCTAssertTrue(LiveSessionCameraPolicy.startsCamera(modelSupportsVision: true, audioOnly: false))
    }

    func testAudioOnlyModeKeepsTheCameraOff() {
        XCTAssertFalse(LiveSessionCameraPolicy.startsCamera(modelSupportsVision: true, audioOnly: true))
    }

    func testAModelThatCannotSeeNeverStartsIt() {
        XCTAssertFalse(LiveSessionCameraPolicy.startsCamera(modelSupportsVision: false, audioOnly: false))
        XCTAssertFalse(LiveSessionCameraPolicy.startsCamera(modelSupportsVision: false, audioOnly: true))
    }

    // MARK: - The claim sees the world the mode leaves it

    /// Why the mode's own start mattered: a claim arriving at a stream that is already running
    /// takes it for somebody else's and leaves it running when it goes.
    func testAClaimOnAnOwnerlessStreamNeverStopsIt() {
        var claims = CameraStreamClaims()
        XCTAssertEqual(claims.claim(.liveSession, streamRunning: true), .alreadyRunning)
        XCTAssertEqual(claims.release(.liveSession, streamRunning: true, otherConsumersActive: false),
                       .keepRunning)
    }

    /// With nothing started before it, the session's claim starts the stream and stops it.
    func testASessionThatStartedTheStreamStopsIt() {
        var claims = CameraStreamClaims()
        XCTAssertEqual(claims.claim(.liveSession, streamRunning: false), .startStream)
        XCTAssertEqual(claims.release(.liveSession, streamRunning: true, otherConsumersActive: false),
                       .stopStream)
    }

    // MARK: - Source

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The source with whole-line comments removed, so prose about a call is never mistaken for it.
    private func code(_ path: String) throws -> String {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func slice(of code: String, from opening: String, to closing: String,
                       _ what: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: opening), "the source no longer has \(what)")
        let rest = code[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: closing), "could not find the end of \(what)")
        return rest[..<end.lowerBound]
    }

    /// Choosing a live mode starts no camera: the session claims it when one begins.
    func testSwitchingToALiveModeStartsNoCamera() throws {
        let appState = try code("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let substrate = try slice(of: appState, from: "case .startSubstrate(let target):",
                                  to: "case .startSession(let target):", "the mode switch's substrate start")
        XCTAssertFalse(substrate.contains("startStreaming("),
                       "a mode switch starts the glasses camera with no owner again: the live "
                           + "session's claim will take it for somebody else's and never stop it")
        XCTAssertFalse(substrate.contains("claimStream("),
                       "the mode switch claims the camera itself: only a session should")
    }

    /// Launching into a live mode starts no camera either.
    func testLaunchingIntoALiveModeStartsNoCamera() throws {
        let appState = try code("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        let launch = try slice(of: appState, from: "private func startModeSubstrateOnLaunch() {",
                               to: "\n    }\n", "`startModeSubstrateOnLaunch()`")
        XCTAssertFalse(launch.contains("startStreaming("),
                       "launching into a live mode turns the capture LED on with no session again")
        XCTAssertFalse(launch.contains("claimStream("))
    }

    /// Every camera start a live session makes asks the policy first, so Audio-Only Mode holds.
    func testEverySessionCameraStartAsksThePolicy() throws {
        let manager = try code("OpenGlasses/Sources/Services/Realtime/RealtimeSessionManager.swift")
        let uses = manager.split(separator: "\n").filter {
            $0.contains("onRequestStartCamera") && !$0.contains("var onRequestStartCamera")
        }
        XCTAssertEqual(uses.count, 3, "a camera start was added or removed: check it asks `startsCamera`")
        for line in uses {
            XCTAssertTrue(line.contains("startsCamera"),
                          "a live-session camera start ignores Audio-Only Mode: \(line)")
        }
        XCTAssertTrue(manager.contains("LiveSessionCameraPolicy.startsCamera(modelSupportsVision: supportsVision,"))
        XCTAssertTrue(manager.contains("audioOnly: Config.audioOnlyMode)"))
    }
}
