import XCTest
@testable import OpenGlasses

/// Plan HX P1 — keeps the glasses' thermal and compatibility readings wired to what acts on them.
///
/// The decisions are pure and tested where they live (`CompatibilityNoticePolicyTests`,
/// `SDKRefusalLatchTests`, `PowerPolicyServiceTests`). Three of their callers cannot run in a
/// unit-test host: `AppState` reaches the wake word, the camera and the live sessions, and the
/// Meta backend's session-error watcher sits behind `Wearables`, which traps here. Those callers
/// are where the gap was (a reading nothing read, a refusal forgotten every cycle), so, like the
/// link cue's guard, this reads the source.
final class GlassesDeviceStateWiringSourceGuardTests: XCTestCase {

    private static let appState = "OpenGlasses/Sources/App/OpenGlassesApp.swift"
    private static let metaBackend = "OpenGlasses/Sources/Services/Camera/MetaCameraBackend.swift"
    private static let linkSource = "OpenGlasses/Sources/Services/GlassesLinkSource.swift"

    /// `#filePath` is baked in at compile time and the simulator shares the host filesystem — the
    /// same anchor `TelemetryOptOutGuardTests` uses.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The source with whole-line `//` comments dropped, so prose that names a call is not
    /// mistaken for the call.
    private func code(_ path: String) throws -> String {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `opening` up to (not including) the next `closing`.
    private func slice(of code: String, from opening: String, to closing: String,
                       _ what: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: opening), "the source no longer has \(what)")
        let rest = code[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: closing), "could not find the end of \(what)")
        return rest[..<end.lowerBound]
    }

    // MARK: - The link source reads both

    func testTheSeedAndTheListenerBothCarryThermalAndCompatibility() throws {
        let observe = try slice(of: try code(Self.linkSource),
                                from: "guard let device = Wearables.shared.deviceForIdentifier(id) else { return nil }",
                                to: "return SDKListenerObservation(token)",
                                "`WearablesGlassesLinkSource.observeDeviceState`")
        XCTAssertTrue(observe.contains("thermal: Self.map(device.thermalLevel)"))
        XCTAssertTrue(observe.contains("compatibility: Self.map(device.compatibility())"))
        XCTAssertTrue(observe.contains("thermal: Self.map(state.thermalLevel)"),
                      "the device-state listener no longer maps the thermal level")
        XCTAssertTrue(observe.contains("compatibility: Self.map(state.compatibility)"),
                      "the device-state listener no longer maps compatibility")
        XCTAssertFalse(observe.contains("hingeState"), "the hinge is not read (Plan HX non-goal)")
    }

    // MARK: - AppState acts on them

    func testThePowerPostureIsFedTheConnectionServicesThermalReading() throws {
        let appState = try code(Self.appState)
        let wiring = try slice(of: appState, from: "private func configurePower() {",
                               to: "power.lowPowerMode", "`configurePower()`")
        XCTAssertTrue(wiring.contains("power.glassesThermal = {"),
                      "the glasses' thermal reading no longer reaches PowerPolicyService")
        XCTAssertTrue(wiring.contains("glassesService.thermal.map { ThermalPressure($0) }"),
                      "the posture must read the connection service's live reading, which is nil "
                          + "whenever the link is down")
        XCTAssertTrue(appState.contains("glassesService.$thermal"),
                      "a thermal change no longer re-evaluates the posture when it happens")
    }

    func testACompatibilityReadingDecidesTheNoticeAndNothingElse() throws {
        let appState = try code(Self.appState)
        XCTAssertTrue(appState.contains("glassesService.$compatibility"),
                      "nothing listens to the glasses' compatibility reading any more")
        let body = try slice(of: appState,
                             from: "private func glassesCompatibilityChanged(_ compatibility: GlassesCompatibility?) {",
                             to: "\n    }\n", "`glassesCompatibilityChanged(_:)`")
        XCTAssertTrue(body.contains("compatibilityNotices.note(compatibility)"),
                      "the update notice is no longer decided by CompatibilityNoticePolicy: it is "
                          + "either never said or said at every reconnection")
        // On screen for as long as it is true, under a source of its own (Plan HX follow-up).
        let standing = try XCTUnwrap(body.range(of: "switch CompatibilityNoticePolicy.standing(for: compatibility) {"),
                                     "the update notice is no longer shown and withdrawn by the "
                                         + "reading: it outlives the requirement, or never shows")
        XCTAssertTrue(body.contains("NoticeCenter.shared.post(message, severity: .warning, source: .glassesUpdate)"))
        XCTAssertTrue(body.contains("NoticeCenter.shared.clear(source: .glassesUpdate)"),
                      "nothing takes the update notice back when the glasses are updated or go")
        let announce = try XCTUnwrap(body.range(of: "compatibilityNotices.note(compatibility)"))
        XCTAssertLessThan(standing.lowerBound, announce.lowerBound,
                          "the notice must be shown or withdrawn at every reading, before the "
                              + "once-per-process rule returns for one that was already said")
        XCTAssertTrue(body.contains("CompatibilityNoticePolicy.delivery("),
                      "the notice no longer waits for the route: it can land on the assistant's voice")
        XCTAssertTrue(body.contains("compatibilityNotices.isOwed(message)"),
                      "the notice must be re-checked when it is about to be said: the glasses may "
                          + "have gone, and it is only said while they are connected")
        XCTAssertFalse(body.contains("cameraService"),
                       "a compatibility reading must not stop the camera by itself: the SDK calls "
                           + "it \"some features may be unavailable\", and only a session the "
                           + "glasses refuse says the camera is one of them (SDKRefusalLatch)")
    }

    func testTheCamerasOwnNoticeSharesTheRecord() throws {
        let sink = try slice(of: try code(Self.appState),
                             from: "let compatToken = cameraService.$compatibilityNotice",
                             to: "cancellables.append(compatToken)", "the camera compatibility sink")
        let claim = try XCTUnwrap(sink.range(of: "guard self.compatibilityNotices.claim(notice) else { return }"),
                                  "the camera's compatibility notice no longer checks the shared "
                                      + "record: a refused build is announced twice")
        let speak = try XCTUnwrap(sink.range(of: "speechService.speak(notice)"))
        XCTAssertLessThan(claim.lowerBound, speak.lowerBound)
    }

    /// The camera clears and replaces the glasses' notices every session cycle. The update notice
    /// is not one of them: only the reading posts it and only the reading takes it back.
    func testOnlyTheReadingTouchesTheUpdateNotice() throws {
        let camera = try code("OpenGlasses/Sources/Services/CameraService.swift")
        XCTAssertFalse(camera.contains(".glassesUpdate"),
                       "the camera must not post or clear the glasses' update notice")
        let appState = try code(Self.appState)
        XCTAssertEqual(appState.components(separatedBy: "source: .glassesUpdate").count, 3,
                       "one post and one clear, both in `glassesCompatibilityChanged(_:)`")
    }

    // MARK: - The backend reports the refusal

    func testTheSessionErrorWatcherReportsARefusalOfTheBuild() throws {
        let backend = try code(Self.metaBackend)
        let watcher = try slice(of: backend,
                                from: "private func watchSessionErrors(on session: DeviceSession) {",
                                to: "\n    }\n", "`watchSessionErrors(on:)`")
        XCTAssertTrue(watcher.contains("if DATCompatibilityMessage.isSDKRefusal(error) { self.events.send(.sdkRefused) }"),
                      "the session-error watcher no longer reports insufficientSDKVersion to the "
                          + "coordinator: the refusal is rediscovered on every start again")
        let advisory = try XCTUnwrap(watcher.range(of: "DATCompatibilityMessage.advisory(for: error)"))
        let refusal = try XCTUnwrap(watcher.range(of: "isSDKRefusal(error)"))
        XCTAssertLessThan(advisory.lowerBound, refusal.lowerBound,
                          "an advisory must leave the loop before anything is latched on it")
    }

    func testThePerCycleClearIsStillThere() throws {
        let retry = try slice(of: try code(Self.metaBackend),
                              from: "private func ensureSessionWithRetry() async throws {",
                              to: "for attempt in 1...4 {", "`ensureSessionWithRetry()`")
        XCTAssertTrue(retry.contains("compatibilityNotice = nil"),
                      "the backend must go on clearing its notice each cycle: a notice from "
                          + "before a glasses update must not block attempts that would now succeed")
    }
}
