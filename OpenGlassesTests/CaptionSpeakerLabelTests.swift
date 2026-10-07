import XCTest
@testable import OpenGlasses

/// Diarized captions keep their speaker where they outlive the chips: the recording transcript,
/// the meeting assistant's transcript and the live HUD line all use the same label.
@MainActor
final class CaptionSpeakerLabelTests: XCTestCase {

    private var suite: UserDefaults!
    private var registry: SpeakerRegistry!

    override func setUp() {
        super.setUp()
        let name = "CaptionSpeakerLabelTests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: name)
        suite.removePersistentDomain(forName: name)
        registry = SpeakerRegistry(defaults: suite, storageKey: "names")
    }

    private func entry(_ text: String, speaker: Int?) -> AmbientCaptionService.CaptionEntry {
        AmbientCaptionService.CaptionEntry(text: text, timestamp: Date(), seq: 1, speaker: speaker)
    }

    func testNamedSpeakerLeadsTheLine() {
        registry.setName("Alice", for: 0)
        XCTAssertEqual(entry("we ship Friday", speaker: 0).labeledText(registry: registry), "Alice: we ship Friday")
    }

    func testUnnamedDiarizedSpeakerIsNumberedFromOne() {
        XCTAssertEqual(entry("agreed", speaker: 1).labeledText(registry: registry), "Speaker 2: agreed")
    }

    func testUndiarizedCaptionIsTheBareText() {
        XCTAssertEqual(entry("hello", speaker: nil).labeledText(registry: registry), "hello")
    }

    func testMeetingTranscriptLineFallsBackToBareTextWithoutARegistry() {
        XCTAssertEqual(MeetingAssistantService.transcriptLine(for: entry("hi", speaker: 0), registry: nil), "hi")
        registry.setName("Bob", for: 0)
        XCTAssertEqual(MeetingAssistantService.transcriptLine(for: entry("hi", speaker: 0), registry: registry),
                       "Bob: hi")
    }
}
