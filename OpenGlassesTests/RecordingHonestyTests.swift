import XCTest
@testable import OpenGlasses

/// Plan GB P4 — recordings: honest filing outcomes, the in-app video list, serial frame appends,
/// and a diagnostics ring that capture noise cannot flood.
final class RecordingHonestyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("GBRec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func source() throws -> URL {
        let url = root.appendingPathComponent("tmp.mp4")
        try Data("footage".utf8).write(to: url)
        return url
    }

    // MARK: - RecordingFiler outcomes

    func testAFailedEncodeSaysSoAndNeverClaimsNothingWasLost() throws {
        let filer = RecordingFiler(recordingsDirectory: root.appendingPathComponent("Recordings"))
        var outcome = filer.file(try source(), date: Date(), saveToPhotos: true)
        outcome.encodeFailed = true
        outcome.playable = false
        let message = try XCTUnwrap(outcome.message)
        XCTAssertTrue(message.contains("couldn't be finished properly"))
        XCTAssertTrue(message.contains("wasn't added to Photos"))
        XCTAssertFalse(message.contains("nothing was lost"))
    }

    func testAnUnplayableFileIsNotReportedAsSafe() throws {
        let filer = RecordingFiler(recordingsDirectory: root.appendingPathComponent("Recordings"))
        var outcome = filer.file(try source(), date: Date(), saveToPhotos: false)
        outcome.playable = false
        XCTAssertFalse(outcome.message?.contains("nothing was lost") ?? false)
        XCTAssertNotNil(outcome.message)
    }

    func testReassuranceOnlyForAPlayableFile() throws {
        let filer = RecordingFiler(recordingsDirectory: root.appendingPathComponent("Recordings"))
        var outcome = filer.file(try source(), date: Date(), saveToPhotos: true)
        outcome.savedToPhotos = false
        XCTAssertEqual(outcome.message, "Couldn't save the recording to Photos. The recording is safe in "
                       + "the app's Recordings folder.")
        outcome.playable = true
        XCTAssertTrue(outcome.message?.hasSuffix("— nothing was lost.") ?? false)
    }

    func testTheRecorderSkipsPhotosForAFailedEncode() throws {
        let service = try source(named: "Services/VideoRecordingService.swift")
        XCTAssertTrue(service.contains("if wantsPhotos, encodeFailed || outcome.playable == false {"))
        XCTAssertTrue(service.contains("guard writer.startWriting() else {"))
        XCTAssertTrue(service.contains(".receive(on: appendQueue)"))
    }

    /// Frames are appended in order on one serial queue — never the concurrent global queue.
    func testNoRecorderAppendsFramesOnTheConcurrentGlobalQueue() throws {
        for file in ["Services/VideoRecordingService.swift", "Services/WebRTCStreamingService.swift",
                     "Services/FieldAssist/Job/JobClipRecorder.swift"] {
            XCTAssertFalse(try source(named: file).contains("receive(on: DispatchQueue.global"), file)
        }
    }

    // MARK: - The video list

    func testVideoListShowsOnlyVideosNewestFirst() throws {
        let dir = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("Recording_2026-09-01_100000.mp4")
        let new = dir.appendingPathComponent("Recording_2026-09-30_100000.mov")
        for (url, age) in [(old, -3600.0), (new, 0)] {
            try Data(repeating: 1, count: 10).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)],
                                                  ofItemAtPath: url.path)
        }
        try Data("t".utf8).write(to: dir.appendingPathComponent("Recording_2026-09-30_100000.txt"))
        try Data("a".utf8).write(to: dir.appendingPathComponent("meeting.m4a"))

        let list = RecordedVideo.list(in: dir)
        XCTAssertEqual(list.map(\.url.lastPathComponent), [new.lastPathComponent, old.lastPathComponent])
        XCTAssertEqual(list.first?.bytes, 10)
        XCTAssertTrue(RecordedVideo.list(in: root.appendingPathComponent("missing")).isEmpty)
    }

    // MARK: - Diagnostics ring

    func testFrameReceivedCannotPushOutModelEvents() {
        let ring = DiagnosticRing(capacity: 100)
        let model = PrivacyEvent(.model, .model, [.init(.event, .token(PrivacyToken("turnStarted")))])
        ring.record(model, line: "[model] turnStarted")
        for i in 0..<300 {
            let frame = PrivacyEvent(.capture, .camera, [
                .init(.source, .token(PrivacyToken("glasses"))),
                .init(.event, .token(PrivacyToken("frameReceived"))),
                .init(.count, .count(i)),
            ])
            ring.record(frame, line: "[capture] camera frameReceived count=\(i)")
        }
        let entries = ring.entries
        XCTAssertEqual(entries.filter { $0.line.contains("frameReceived") }.count, DiagnosticRing.frameReceivedBudget)
        XCTAssertTrue(entries.contains { $0.line == "[model] turnStarted" })
        XCTAssertTrue(entries.last?.line.hasSuffix("count=299") ?? false, "the newest frame is kept")
    }

    // MARK: - Helpers

    private func source(named path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources").appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
