import XCTest
@testable import OpenGlasses

/// `device_info`'s words about the in-lens Display: connected, switched on, whose the lens is, and
/// how the last send ended. All pure: the reading is built by hand, no DAT and no AppState.
final class DisplayStatusWordingTests: XCTestCase {

    private func ready(_ change: (inout DisplayStatusReading) -> Void = { _ in }) -> DisplayStatusReading {
        var reading = DisplayStatusReading(backend: .metaDisplay, glassesPhase: .connected, hasDisplay: true,
                                           hudEnabled: true, availability: .ours, worn: true,
                                           dismissedByWearer: false,
                                           lastSend: HUDSendRecord(kind: .text, milliseconds: 48, outcome: .sent))
        change(&reading)
        return reading
    }

    private func text(_ reading: DisplayStatusReading) -> String {
        DisplayStatusWording.lines(reading).joined(separator: ". ")
    }

    // MARK: - Connected means the link, nothing else

    func testEachUnconnectedPhaseSaysTheDisplayIsUnavailable() {
        let cases: [(GlassesConnectionPhase, String)] = [
            (.noGlassesAdded, "No glasses are added"),
            (.addedDisconnected, "The glasses aren't connected"),
            (.connecting, "still connecting"),
        ]
        for (phase, expected) in cases {
            // Whatever else is true, a link that is not up is the whole answer.
            let lines = DisplayStatusWording.lines(ready { $0.glassesPhase = phase })
            XCTAssertEqual(lines.count, 1, "\(phase)")
            XCTAssertTrue(lines[0].contains(expected), "\(phase): \(lines[0])")
            XCTAssertTrue(lines[0].contains("display"), "\(phase): \(lines[0])")
        }
    }

    func testConnectedGlassesWithoutADisplaySaySo() {
        XCTAssertEqual(DisplayStatusWording.lines(ready { $0.hasDisplay = false }),
                       ["The connected glasses don't have an in-lens display"])
    }

    // MARK: - The HUD switch and whose the lens is

    func testReadyDisplayWithASentFrame() {
        XCTAssertEqual(DisplayStatusWording.lines(ready()), [
            "Display glasses are connected",
            "The display is on and ready to show things",
            "The last thing sent to the display (text) reached the glasses",
        ])
    }

    func testSwitchedOffHUDIsTheAnswerAndHidesTheLastSend() {
        let lines = DisplayStatusWording.lines(ready { $0.hudEnabled = false; $0.availability = .off })
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("switched off in Settings"))
        XCTAssertFalse(text(ready { $0.hudEnabled = false }).contains("last thing sent"))
    }

    func testInUseByAnotherApp() {
        let lines = DisplayStatusWording.lines(ready { $0.availability = .inUse })
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("Another app is using the display"))
    }

    func testOffReadingSaysNotWornOnlyWhenTheGlassesSaySo() {
        XCTAssertTrue(text(ready { $0.availability = .off; $0.worn = false }).contains("not being worn"))
        let unknown = text(ready { $0.availability = .off; $0.worn = nil })
        XCTAssertTrue(unknown.contains("The display is off right now"))
        XCTAssertFalse(unknown.contains("worn"))
    }

    func testDismissedByTheWearer() {
        XCTAssertTrue(text(ready { $0.dismissedByWearer = true }).contains("the wearer closed it"))
    }

    // MARK: - The last send

    func testEveryOutcomeOfTheLastSend() {
        let cases: [(HUDSendRecord.Outcome, String)] = [
            (.sent, "reached the glasses"),
            (.failed, "failed to reach the glasses"),
            (.timedOut, "timed out"),
            (.retriedWithoutPicture, "sent again as text"),
        ]
        for (outcome, expected) in cases {
            let line = DisplayStatusWording.lastSendLine(HUDSendRecord(kind: .picture, milliseconds: 4000,
                                                                       outcome: outcome))
            XCTAssertTrue(line.contains(expected), "\(outcome): \(line)")
        }
        XCTAssertEqual(DisplayStatusWording.lastSendLine(nil),
                       "Nothing has been sent to the display since the app started")
    }

    func testEveryKindHasPlainWords() {
        let kinds: [HUDSendRecord.Kind] = [.text, .screen, .picture, .clear, .video]
        let lines = kinds.map {
            DisplayStatusWording.lastSendLine(HUDSendRecord(kind: $0, milliseconds: 1, outcome: .sent))
        }
        XCTAssertEqual(Set(lines).count, kinds.count, "each kind is worded apart")
    }

    // MARK: - EVEN G2

    func testEvenG2IsNotClaimedConnectedOnlyPaired() {
        var even = ready { $0.backend = .evenG2; $0.glassesPhase = .noGlassesAdded }
        let lines = DisplayStatusWording.lines(even)
        XCTAssertTrue(lines[0].contains("EVEN G2"))
        XCTAssertTrue(lines[0].contains("paired"))
        XCTAssertFalse(lines[0].contains("are connected"))
        XCTAssertTrue(lines.last?.contains("reached the glasses") == true)

        even.hasDisplay = false
        XCTAssertEqual(DisplayStatusWording.lines(even),
                       ["The in-lens display is set to EVEN G2, but no EVEN G2 glasses are paired"])
    }

    // MARK: - No SDK words, no content

    /// What the model reads aloud carries no case names (`inUse`, `timed-out`, `metaRayBan`) and
    /// never ends a sentence itself (the tool joins them).
    func testNoCaseNamesAcrossEveryReading() {
        let banned = ["inUse", "timed-out", "timedOut", "retried-without-picture", "metaRayBan", "evenG2",
                      "addedDisconnected", "noGlassesAdded", "ours", "paused", "session"]
        let outcomes: [HUDSendRecord.Outcome] = [.sent, .failed, .timedOut, .retriedWithoutPicture]
        let kinds: [HUDSendRecord.Kind] = [.text, .screen, .picture, .clear, .video]
        let records: [HUDSendRecord?] = [nil] + outcomes.flatMap { outcome in
            kinds.map { HUDSendRecord(kind: $0, milliseconds: 1234, outcome: outcome) }
        }
        let phases: [GlassesConnectionPhase] = [.noGlassesAdded, .addedDisconnected, .connecting, .connected]
        var checked = 0
        for backend in [DisplayStatusReading.Backend.metaDisplay, .evenG2] {
            for phase in phases {
                for hasDisplay in [true, false] {
                    for enabled in [true, false] {
                        for availability in DisplayAvailability.allCases {
                            for worn in [true, false, nil] as [Bool?] {
                                for dismissed in [true, false] {
                                    for record in records {
                                        let reading = DisplayStatusReading(
                                            backend: backend, glassesPhase: phase, hasDisplay: hasDisplay,
                                            hudEnabled: enabled, availability: availability, worn: worn,
                                            dismissedByWearer: dismissed, lastSend: record)
                                        let lines = DisplayStatusWording.lines(reading)
                                        XCTAssertFalse(lines.isEmpty)
                                        for line in lines {
                                            XCTAssertFalse(line.hasSuffix("."), line)
                                            XCTAssertFalse(line.contains("1234"), "no timings: \(line)")
                                            for word in banned {
                                                XCTAssertFalse(line.contains(word), "\(word) in: \(line)")
                                            }
                                        }
                                        checked += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
    }

    // MARK: - The tool's argument

    func testToolPartArgument() {
        XCTAssertEqual(DeviceInfoTool.Part(argument: "phone"), .phone)
        XCTAssertEqual(DeviceInfoTool.Part(argument: "Display"), .display)
        XCTAssertEqual(DeviceInfoTool.Part(argument: "hud"), .display)
        XCTAssertEqual(DeviceInfoTool.Part(argument: nil), .both)
        XCTAssertEqual(DeviceInfoTool.Part(argument: "everything"), .both)
        XCTAssertTrue(DeviceInfoTool.Part.both.includesPhone && DeviceInfoTool.Part.both.includesDisplay)
        XCTAssertFalse(DeviceInfoTool.Part.phone.includesDisplay)
        XCTAssertFalse(DeviceInfoTool.Part.display.includesPhone)
    }

    /// A tier-0 battery question is spoken as the tool words it, so it asks for the phone only;
    /// a bare "device info" still gets everything.
    func testBatteryQuestionAsksForThePhoneOnly() {
        let classifier = ConversationClassifier()
        let battery = classifier.classify("how much battery").directToolCall
        XCTAssertEqual(battery?.toolName, "device_info")
        XCTAssertEqual(battery?.arguments["about"] as? String, "phone")
        let everything = classifier.classify("device info").directToolCall
        XCTAssertEqual(everything?.toolName, "device_info")
        XCTAssertNil(everything?.arguments["about"])
    }
}
