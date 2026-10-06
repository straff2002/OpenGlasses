import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 5 — a saved recording goes to Deepgram only when cloud diarization is switched
/// on, not merely because a key is present; and speaker naming is screened as not biometric.
///
/// The on-device engine is given an empty model folder so it is never ready: the outcome then says
/// whether the cloud upload was attempted (`.failure`, carrying the provider's error) or skipped
/// (`.unavailable`, the "configure something" answer). No network is reached either way — the file
/// does not exist, and no Keychain key is needed.
@MainActor
final class RecordingTranscriberDiarizationGateTests: XCTestCase {

    private var modelDir: URL!
    private var savedDiarization: Any?

    override func setUp() {
        super.setUp()
        modelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTranscriberGate_\(UUID().uuidString)", isDirectory: true)
        savedDiarization = UserDefaults.standard.object(forKey: "diarizationEnabled")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: modelDir)
        if let savedDiarization {
            UserDefaults.standard.set(savedDiarization, forKey: "diarizationEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "diarizationEnabled")
        }
        super.tearDown()
    }

    private var missingRecording: URL {
        modelDir.appendingPathComponent("recording.m4a")
    }

    private func notReadyEngine() -> OnDeviceASREngine {
        OnDeviceASREngine(modelStore: ASRModelStore(directory: modelDir))
    }

    private static let unavailable = RecordingTranscriptionOutcome.unavailable(
        "Configure Deepgram or download the on-device speech recognition model.")

    func testNoUploadWhenTheGateIsClosed() async {
        let transcriber = RecordingTranscriber(onDeviceEngine: notReadyEngine(), deepgramAllowed: { false })
        let outcome = await transcriber.transcribe(fileURL: missingRecording)
        XCTAssertEqual(outcome, Self.unavailable, "Deepgram was tried with the gate closed")
    }

    func testUploadIsAttemptedWhenTheGateIsOpen() async {
        let transcriber = RecordingTranscriber(onDeviceEngine: notReadyEngine(), deepgramAllowed: { true })
        let outcome = await transcriber.transcribe(fileURL: missingRecording)
        guard case .failure = outcome else {
            return XCTFail("expected the Deepgram attempt to fail and be reported, got \(outcome)")
        }
    }

    /// The default gate is the diarization opt-in: with the switch off, a recording never goes to
    /// Deepgram, whatever key is or is not on the phone.
    func testTheDefaultGateHonoursTheDiarizationSwitch() async {
        Config.diarizationEnabled = false
        XCTAssertFalse(Config.isDiarizationConfigured)
        let transcriber = RecordingTranscriber(onDeviceEngine: notReadyEngine())
        let outcome = await transcriber.transcribe(fileURL: missingRecording)
        XCTAssertEqual(outcome, Self.unavailable)
    }

    // MARK: - Screening

    func testSpeakerIdentificationIsScreenedNotBiometricAndSaysWhy() throws {
        let record = AIFeature.speakerIdentification.record
        XCTAssertEqual(record.sensitiveCategories, [.none])
        let note = try XCTUnwrap(record.screeningNote)
        XCTAssertTrue(note.contains("cluster id"))
        XCTAssertTrue(note.contains("no voiceprint"))
        // Its switch is still the diarization opt-in, which is now also the upload gate.
        XCTAssertEqual(record.disableSwitch.key, "diarizationEnabled")
    }
}
