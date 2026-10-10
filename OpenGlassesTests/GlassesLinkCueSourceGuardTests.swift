import XCTest
@testable import OpenGlasses

/// Plan HX P0 — keeps the link-lost cue wired to the place the glasses are actually lost.
///
/// `GlassesLinkCuePolicyTests` proves the decision. It cannot prove the decision is *asked*: the
/// one caller is `AppState.isConnected`'s `didSet`, which cannot run in a unit-test host (it
/// reaches the wake word, the camera and the live sessions). That caller is exactly where the
/// original defect lived — a teardown that released the hardware and then said nothing — and a
/// refactor of the teardown could quietly put it back. So, as with the telemetry backstop's
/// ordering, this reads the source, which is where the order is decided.
final class GlassesLinkCueSourceGuardTests: XCTestCase {

    private static let appState = "OpenGlasses/Sources/App/OpenGlassesApp.swift"

    /// `#filePath` is baked in at compile time and the simulator shares the host filesystem — the
    /// same anchor `TelemetryOptOutGuardTests` uses.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)   // <repo>/OpenGlassesTests/<thisfile>.swift
            .deletingLastPathComponent()  // <repo>/OpenGlassesTests
            .deletingLastPathComponent()  // <repo>
    }

    /// The source with whole-line `//` comments dropped, so prose that names a call is not
    /// mistaken for the call.
    private func appStateCode() throws -> String {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(Self.appState),
                                encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text from `opening` up to (not including) the next `closing`.
    private func slice(of code: String, from opening: String, to closing: String,
                       _ what: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: opening), "\(Self.appState) no longer has \(what)")
        let rest = code[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: closing), "could not find the end of \(what)")
        return rest[..<end.lowerBound]
    }

    /// The branch `isConnected`'s `didSet` runs when the glasses go out of use.
    private func lossBranch(in code: String) throws -> Substring {
        try slice(of: code, from: "if !isConnected && oldValue {",
                  to: "} else if isConnected && !oldValue {",
                  "the `!isConnected && oldValue` branch in `isConnected`'s didSet")
    }

    private func body(of function: String, in code: String) throws -> Substring {
        // Up to the next member at the same indentation: good enough for a "does it still call
        // this" question, and it does not pretend to parse Swift.
        try slice(of: code, from: "private func \(function)() {", to: "\n    }\n",
                  "`\(function)()`")
    }

    /// The release stops speech; the cue must come after it, and must still be there.
    func testTheLossPathReleasesTheHardwareAndThenDecidesTheCue() throws {
        let branch = try lossBranch(in: try appStateCode())

        let release = try XCTUnwrap(branch.range(of: "releaseGlassesHardware()"),
                                    "the loss path no longer releases the glasses hardware")
        let cue = try XCTUnwrap(branch.range(of: "cueGlassesOutOfUse()"),
                                "the loss path no longer decides the link-lost cue: a dropped "
                                    + "link is silent again, and a wearer with the phone in a "
                                    + "pocket is talking to glasses that have gone")
        XCTAssertLessThan(release.lowerBound, cue.lowerBound,
                          "the link-lost cue must be decided after releaseGlassesHardware(): the "
                              + "release is what stops the assistant's voice, and the cue must "
                              + "not land on top of it")
    }

    /// The function the loss path calls really asks the policy, with the value from before the
    /// change, and really plays the link's own earcon.
    func testTheCueIsDecidedByThePolicyAndPlaysTheLinkLostEarcon() throws {
        let body = try body(of: "cueGlassesOutOfUse", in: try appStateCode())

        XCTAssertTrue(body.contains("glassesLinkCues.noteLoss(from: appliedGlassesUse, to: glassesUse"),
                      "cueGlassesOutOfUse() no longer asks GlassesLinkCuePolicy.Ledger, or no "
                          + "longer hands it the GlassesUse from before the change — which is "
                          + "the only thing that tells a dropped link from a Disconnect")
        XCTAssertTrue(body.contains("glassesService.snapshot.lastLiveWorn"),
                      "the worn reading must be the one remembered from while the link was up; "
                          + "the live one is already nil when the link has gone")
        XCTAssertTrue(body.contains("GlassesLinkCuePolicy.delivery("),
                      "the cue no longer waits for the route: it can land on the assistant's voice")
        XCTAssertTrue(body.contains("speechService.playLinkLostTone()"),
                      "the link-lost cue no longer plays its earcon")
        XCTAssertFalse(body.contains("playDisconnectTone"),
                       "the link-lost cue is the end-of-conversation pair again: mid-conversation "
                           + "a dropped link sounds like the conversation ending")
        XCTAssertTrue(body.contains("GlassesLinkCuePolicy.lostLineDelaySeconds"),
                      "VoiceOver's line must wait for the earcon, which is longer than the pair "
                          + "it replaced, or it starts under it")
    }

    /// The earcon is the policy's notes, played the way every other multi-note cue is.
    func testTheEarconPlaysThePolicysNotes() throws {
        let path = "OpenGlasses/Sources/Services/TextToSpeechService.swift"
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
        let body = try slice(of: source, from: "func playLinkLostTone() {", to: "\n    }\n",
                             "`playLinkLostTone()`")
        XCTAssertTrue(body.contains("for note in GlassesLinkCuePolicy.lostEarcon"))
        XCTAssertTrue(body.contains("playTone(frequency: note.frequency, duration: note.duration)"))
        // The Blind Assistant's "connection dropped" keeps the pair it was taught with.
        XCTAssertTrue(source.contains("case .lost: playDisconnectTone()"))
    }

    /// `appliedGlassesUse` is only "the value from before" if it is written after `isConnected`.
    func testTheAppliedValueIsRecordedAfterTheMirrorsAreWritten() throws {
        let body = try body(of: "applyGlassesUse", in: try appStateCode())

        let write = try XCTUnwrap(body.range(of: "isConnected = glassesUse.inUse"))
        let record = try XCTUnwrap(body.range(of: "appliedGlassesUse = glassesUse"),
                                   "applyGlassesUse() no longer records what it applied")
        XCTAssertLessThan(write.lowerBound, record.lowerBound,
                          "appliedGlassesUse must be written after isConnected: its didSet reads "
                              + "it as the value from before the change")
    }

    /// The restore side keeps the tone every connection has always had.
    func testTheRestorePathStillPlaysTheConnectTone() throws {
        let code = try appStateCode()
        let didSet = try slice(of: code, from: "} else if isConnected && !oldValue {",
                               to: "PrivacyLog.device(.glasses, .connected)",
                               "the `isConnected && !oldValue` branch in `isConnected`'s didSet")
        XCTAssertTrue(didSet.contains("cueGlassesInUse()"))
        XCTAssertTrue(try body(of: "cueGlassesInUse", in: code).contains("speechService.playConnectTone()"),
                      "a connection no longer plays the connect tone")
    }

    /// VoiceOver's own line is withheld only on the ledger's say-so.
    func testTheAnnouncementContextReadsTheLedger() throws {
        XCTAssertTrue(try appStateCode().contains("glassesLossCuePlayed: self.glassesLinkCues.appOwnsLossCue"),
                      "the VoiceOver context no longer reads the link-cue ledger: either every "
                          + "disconnect is announced over the cue, or none is announced at all")
    }
}
