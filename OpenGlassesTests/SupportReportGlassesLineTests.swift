import XCTest
@testable import OpenGlasses

/// The support report's line about the glasses video link (2026-10-10). Which radio carried the
/// video is the first thing to know about a stream that was slow or kept dropping, and until now
/// no report said. The line is read by the person sending the report as well as by whoever
/// receives it, so it is plain words: the link, where that was read from, and what the stream
/// delivered. It is always there, because "not known" is an answer and a missing line is not.
final class SupportReportGlassesLineTests: XCTestCase {

    private typealias Reading = GlassesTransportProbe.Reading

    private let delivered = StreamDeliveryMeter.Facts(width: 504, height: 896,
                                                      framesPerSecond: 29.6)

    private func line(_ reading: Reading, delivery: StreamDeliveryMeter.Facts? = nil) -> String {
        GlassesVideoLinkReport.line(for: .init(videoHasRun: true, reading: reading,
                                               delivery: delivery))
    }

    func testBeforeAnyVideoTheLineSaysSo() {
        XCTAssertEqual(GlassesVideoLinkReport.line(for: .noVideo),
                       "Glasses video link: not known (no video since the app started)")
    }

    func testBluetoothClassicFromTheProcessLog() {
        XCTAssertEqual(
            line(.init(level: .bluetoothClassic, origin: .processLog, changedDuringSession: false),
                 delivery: delivered),
            "Glasses video link: Bluetooth Classic (from the glasses software's log); "
                + "picture 504×896 at 30 fps")
    }

    func testWiFiThatChangedDuringTheSession() {
        XCTAssertEqual(
            line(.init(level: .wifi, origin: .processLog, changedDuringSession: true),
                 delivery: delivered),
            "Glasses video link: Wi-Fi (from the glasses software's log), "
                + "changed during the session; picture 504×896 at 30 fps")
    }

    func testBluetoothLowEnergyFromTheLogFile() {
        XCTAssertEqual(
            line(.init(level: .bluetoothLowEnergy, origin: .sdkLogFile,
                       changedDuringSession: false)),
            "Glasses video link: Bluetooth Low Energy (from the glasses software's log file)")
    }

    func testNotKnownStillSaysWhatWasDelivered() {
        XCTAssertEqual(line(.unknown, delivery: delivered),
                       "Glasses video link: not known; picture 504×896 at 30 fps")
    }

    func testNotKnownBeforeAnythingWasMeasured() {
        XCTAssertEqual(line(.unknown), "Glasses video link: not known")
    }

    /// The size and rate are printed for every level alike. They sit beside the level and are
    /// never the reason for it: the same picture is reported under three different links here.
    func testThePictureIsReportedTheSameWhateverTheLink() {
        for level in [GlassesTransportLevel.wifi, .bluetoothClassic, .bluetoothLowEnergy, .unknown] {
            let reading = Reading(level: level, origin: level == .unknown ? .none : .processLog,
                                  changedDuringSession: false)
            XCTAssertTrue(line(reading, delivery: delivered)
                .hasSuffix("; picture 504×896 at 30 fps"), "\(level)")
        }
    }

    private var everyLine: [String] {
        var lines = [GlassesVideoLinkReport.line(for: .noVideo)]
        for level in [GlassesTransportLevel.wifi, .bluetoothClassic, .bluetoothLowEnergy, .unknown] {
            for origin in [Reading.Origin.processLog, .sdkLogFile, .none] {
                for changed in [false, true] {
                    for delivery in [delivered, nil] {
                        lines.append(line(.init(level: level, origin: origin,
                                                changedDuringSession: changed),
                                          delivery: delivery))
                    }
                }
            }
        }
        return lines
    }

    func testTheLineIsAlwaysPresentAndAlwaysOneLine() {
        for line in everyLine {
            XCTAssertTrue(line.hasPrefix("Glasses video link: "), line)
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertGreaterThan(line.count, "Glasses video link: ".count, line)
        }
    }

    /// The person sending the report reads this. No internal plan names, and none of the SDK's
    /// own words for things.
    func testTheLineCarriesNoPlanLettersAndNoJargon() {
        for line in everyLine {
            for word in ["Plan", "HW", "P1", "SDK", "DAT", "MWDAT", "OSLog", "DeviceManager",
                         "medium", "high", "low link", "BTC", "unknown", "nil"] {
                XCTAssertFalse(line.contains(word), "\(word) in: \(line)")
            }
        }
    }

    /// The probe reads lines that name devices. The snapshot the line is built from has no
    /// field a name or an identifier could be carried in: a level, two words and three numbers.
    func testNothingInTheLineCouldBeAnIdentifier() {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :;,()'×-")
        for line in everyLine {
            XCTAssertTrue(line.unicodeScalars.allSatisfy(allowed.contains), line)
            // Every run of digits is the width, the height or the rate that was passed in.
            let numbers = line.split(whereSeparator: { !$0.isNumber }).map(String.init)
            XCTAssertTrue(numbers.allSatisfy { ["504", "896", "30"].contains($0) }, line)
        }
        let fields = Mirror(reflecting: GlassesVideoLinkSnapshot.noVideo).children.compactMap(\.label)
        XCTAssertEqual(fields, ["videoHasRun", "reading", "delivery"])
        let readingFields = Mirror(reflecting: Reading.unknown).children.compactMap(\.label)
        XCTAssertEqual(readingFields, ["level", "origin", "changedDuringSession"])
    }
}
