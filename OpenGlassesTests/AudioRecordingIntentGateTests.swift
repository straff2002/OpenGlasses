import AppIntents
import XCTest
@testable import OpenGlasses

/// The two decisions that keep an `AudioRecordingIntent` inside the rule iOS enforces as an
/// abort: no microphone from the intent without a Live Activity, and no return without one.
final class AudioRecordingIntentGateTests: XCTestCase {

    func testLiveActivitiesSwitchedOffRefusesBeforeTheMicrophoneIsTouched() {
        XCTAssertEqual(AudioRecordingIntentGate.beforeStart(activitiesEnabled: false),
                       .refuse(.liveActivitiesDisabled))
        XCTAssertEqual(AudioRecordingIntentGate.beforeStart(activitiesEnabled: true), .proceed)
    }

    func testAStartWithoutAnActivityOnScreenIsNotReturnedFrom() {
        XCTAssertEqual(AudioRecordingIntentGate.beforeReturn(activityRunning: false),
                       .refuse(.liveActivityMissing))
        XCTAssertEqual(AudioRecordingIntentGate.beforeReturn(activityRunning: true), .proceed)
    }

    /// Only the intent that opens the microphone carries the conformance iOS polices. The two
    /// question intents take their question from Siri and never record; conforming anyway put
    /// them one active audio session away from the same abort.
    func testOnlyTheListeningIntentIsAnAudioRecordingIntent() {
        func recordsAudio(_ type: Any.Type) -> Bool { type is any AudioRecordingIntent.Type }
        XCTAssertTrue(recordsAudio(AskOpenGlassesIntent.self))
        XCTAssertFalse(recordsAudio(AskQuestionIntent.self))
        XCTAssertFalse(recordsAudio(AskPersonaIntent.self))
    }
}
