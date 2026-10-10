import XCTest
@testable import OpenGlasses

/// Plan HX P1 — keeps the glasses' thermal reading wired to what acts on it.
///
/// The decision is pure and tested where it lives (`PowerPolicyServiceTests`). Its callers cannot
/// run in a unit-test host: `AppState` reaches the wake word, the camera and the live sessions,
/// and the link source sits on `Wearables`, which traps here. Those callers are where the gap was
/// (a reading nothing read), so, like the link cue's guard, this reads the source.
final class GlassesDeviceStateWiringSourceGuardTests: XCTestCase {

    private static let appState = "OpenGlasses/Sources/App/OpenGlassesApp.swift"
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
}
