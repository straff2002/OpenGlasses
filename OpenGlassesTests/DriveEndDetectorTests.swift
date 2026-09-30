import CoreLocation
import XCTest
@testable import OpenGlasses

/// Plan GH P0 — when a drive has ended, and where the car is. Every input carries its own clock.
final class DriveEndDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func fix(_ seconds: TimeInterval, lat: Double = -36.85, lon: Double = 174.76) -> DriveEndDetector.Input {
        .fix(LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: 8, at: at(seconds)))
    }

    private func motion(_ kind: MotionSample.Kind, _ seconds: TimeInterval,
                        confidence: MotionSample.Confidence = .high) -> DriveEndDetector.Input {
        .motion(MotionSample(kind, confidence: confidence, at: at(seconds)))
    }

    private func run(_ detector: inout DriveEndDetector,
                     _ inputs: [DriveEndDetector.Input]) -> [DriveEndDetector.Detection] {
        inputs.compactMap { detector.handle($0) }
    }

    private var both: DriveEndDetector.Settings { .init(carPlayCapture: true, motionCapture: true) }
    private var carPlayOnly: DriveEndDetector.Settings { .init(carPlayCapture: true, motionCapture: false) }

    // MARK: - CarPlay

    func testCarPlayShortHopIsIgnored() {
        var detector = DriveEndDetector(settings: carPlayOnly)
        let found = run(&detector, [.carPlayConnected(at: at(0)), fix(60), .carPlayDisconnected(at: at(120))])
        XCTAssertTrue(found.isEmpty)
    }

    func testCarPlayDisconnectAfterADriveSavesACertainSpotAtTheLastFix() {
        var detector = DriveEndDetector(settings: carPlayOnly)
        let found = run(&detector, [
            .carPlayConnected(at: at(0)), fix(100, lat: 1, lon: 1), fix(300, lat: 2, lon: 2),
            .carPlayDisconnected(at: at(330)),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.capture, .carPlayDisconnect)
        XCTAssertEqual(found.first?.confidence, .certain)
        XCTAssertEqual(found.first?.fix.latitude, 2)
        XCTAssertEqual(found.first?.driveEndedAt, at(330))
    }

    func testStaleFixAtCarPlayDisconnectIsProbableAndKeepsItsTime() {
        var detector = DriveEndDetector(settings: carPlayOnly)
        let found = run(&detector, [.carPlayConnected(at: at(0)), fix(60), .carPlayDisconnected(at: at(600))])
        XCTAssertEqual(found.first?.confidence, .probable)
        let spot = found.first?.spot(savedAt: at(600))
        XCTAssertEqual(spot?.locationLag ?? 0, 540, accuracy: 0.001, "the recall needs the fix's real age")
    }

    func testAFixFromBeforeTheDriveIsNeverUsed() {
        var detector = DriveEndDetector(settings: carPlayOnly)
        let found = run(&detector, [fix(-100), .carPlayConnected(at: at(0)), .carPlayDisconnected(at: at(600))])
        XCTAssertTrue(found.isEmpty, "the last fix before connecting is where the drive started")
    }

    func testCarPlayCaptureOffSavesNothing() {
        var detector = DriveEndDetector(settings: .init(carPlayCapture: false, motionCapture: false))
        let found = run(&detector, [.carPlayConnected(at: at(0)), fix(300), .carPlayDisconnected(at: at(310))])
        XCTAssertTrue(found.isEmpty)
    }

    // MARK: - Motion

    func testDriveThenWalkSavesAProbableSpotAtTheDriveEnd() {
        var detector = DriveEndDetector(settings: both)
        var found = run(&detector, [
            motion(.automotive, 0), fix(200, lat: 3, lon: 3), motion(.stationary, 300),
            motion(.walking, 320), fix(340, lat: 9, lon: 9),
        ])
        XCTAssertTrue(found.isEmpty, "thirty seconds on foot have not passed yet")
        XCTAssertEqual(detector.pendingWalkConfirmationAt, at(350))
        found = run(&detector, [.tick(at: at(355))])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.capture, .motion)
        XCTAssertEqual(found.first?.confidence, .probable)
        XCTAssertEqual(found.first?.fix.latitude, 3, "the fix after walking away is not the car")
        XCTAssertEqual(found.first?.driveEndedAt, at(300))
    }

    func testBusPassengerPatternIsIgnoredWithoutIDrive() {
        var detector = DriveEndDetector(settings: carPlayOnly)
        let found = run(&detector, [
            motion(.automotive, 0), fix(200), motion(.stationary, 300), motion(.walking, 310),
            .tick(at: at(400)),
        ])
        XCTAssertTrue(found.isEmpty)
    }

    func testAShortDriveIsIgnored() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            motion(.automotive, 0), fix(30), motion(.walking, 60), .tick(at: at(120)),
        ])
        XCTAssertTrue(found.isEmpty)
    }

    func testAStopAtTheLightsDoesNotEndTheDrive() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            motion(.automotive, 0), motion(.stationary, 200), motion(.automotive, 230),
            fix(390), motion(.stationary, 400), motion(.walking, 410), .tick(at: at(450)),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.driveEndedAt, at(400))
    }

    func testWalkingThatStartsTooLateIsNotParking() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            motion(.automotive, 0), fix(250), motion(.stationary, 300), motion(.walking, 300 + 200),
            .tick(at: at(560)),
        ])
        XCTAssertTrue(found.isEmpty)
    }

    func testLowConfidenceAutomotiveDoesNotStartADrive() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            motion(.automotive, 0, confidence: .low), fix(200), motion(.walking, 300), .tick(at: at(340)),
        ])
        XCTAssertTrue(found.isEmpty)
    }

    func testMotionWithNoFixDuringTheDriveSavesNothing() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            fix(-10), motion(.automotive, 0), motion(.stationary, 300), motion(.walking, 310),
            .tick(at: at(350)),
        ])
        XCTAssertTrue(found.isEmpty, "the app's last fix predates the drive")
    }

    func testReplayedSamplesOlderThanTheLastSeenAreIgnored() {
        var detector = DriveEndDetector(settings: both)
        _ = run(&detector, [motion(.stationary, 500)])
        let found = run(&detector, [
            motion(.automotive, 0), fix(200), motion(.stationary, 300), motion(.walking, 310),
            .tick(at: at(600)),
        ])
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(detector.lastMotionAt, at(500))
    }

    func testCarPlaySaveSuppressesADuplicateMotionSaveForTheSameDrive() {
        var detector = DriveEndDetector(settings: both)
        let found = run(&detector, [
            .carPlayConnected(at: at(0)), motion(.automotive, 5), fix(290),
            .carPlayDisconnected(at: at(300)), motion(.walking, 310), .tick(at: at(350)),
        ])
        XCTAssertEqual(found.map(\.capture), [.carPlayDisconnect])
    }

    // MARK: - Replacement and announcement

    func testAManualSpotIsNotOverwrittenByAnAutomaticOneWithinTenMinutes() {
        let manual = ParkingSpot(level: "2", space: "41", savedAt: at(0), capture: .voice)
        let automatic = ParkingSpot(coordinate: .init(latitude: 1, longitude: 1), savedAt: at(300),
                                    capture: .motion)
        XCTAssertEqual(ParkingReplacementPolicy.resolve(existing: manual, candidate: automatic, now: at(300)),
                       .keepExisting)
        XCTAssertEqual(ParkingReplacementPolicy.resolve(existing: manual, candidate: automatic, now: at(700)),
                       .replace(automatic))
    }

    func testASpokenSpotWithoutAFixKeepsTheMomentsOldAutomaticCoordinate() {
        let automatic = ParkingSpot(coordinate: .init(latitude: 5, longitude: 6), locationAt: at(0),
                                    savedAt: at(0), capture: .carPlayDisconnect)
        let spoken = ParkingSpot(level: "B2", savedAt: at(60), capture: .voice)
        guard case .replace(let merged) = ParkingReplacementPolicy.resolve(existing: automatic,
                                                                          candidate: spoken, now: at(60)) else {
            return XCTFail("a spoken spot always wins")
        }
        XCTAssertEqual(merged.level, "B2")
        XCTAssertEqual(merged.latitude, 5)
        XCTAssertEqual(merged.capture, .voice)
    }

    func testAnnouncementIsSilentExceptAfterCarPlay() {
        XCTAssertEqual(ParkingAutoSaveAnnouncement.plan(for: .carPlayDisconnect), .init(speak: true, notify: true))
        XCTAssertEqual(ParkingAutoSaveAnnouncement.plan(for: .motion), .init(speak: false, notify: true))
        XCTAssertEqual(ParkingAutoSaveAnnouncement.plan(for: .voice), .init(speak: false, notify: false))
    }
}
