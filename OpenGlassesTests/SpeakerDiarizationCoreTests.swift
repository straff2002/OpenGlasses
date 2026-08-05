import XCTest
@testable import OpenGlasses

/// `SpeakerSegmentMerger`, `SpeakerRegistry`, `PCMConverter`, and the single-speaker fallback
/// contract — the rest of the diarization deterministic core.
final class SpeakerDiarizationCoreTests: XCTestCase {

    // MARK: - SpeakerSegmentMerger

    private func seg(_ text: String, speaker: Int?, final: Bool = true,
                     start: Double? = nil, end: Double? = nil) -> DiarizedSegment {
        DiarizedSegment(text: text, speaker: speaker, isFinal: final, start: start, end: end, confidence: 1)
    }

    func testMergeFinalsCoalescesConsecutiveSameSpeaker() {
        let turns = SpeakerSegmentMerger.mergeFinals([
            seg("Hello", speaker: 0, start: 0, end: 1),
            seg("again", speaker: 0, start: 1, end: 2),
            seg("Hi", speaker: 1, start: 2, end: 3)
        ])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speaker, 0)
        XCTAssertEqual(turns[0].text, "Hello again")
        XCTAssertEqual(turns[0].start, 0)
        XCTAssertEqual(turns[0].end, 2)
        XCTAssertEqual(turns[1].speaker, 1)
        XCTAssertEqual(turns[1].text, "Hi")
    }

    func testMergeFinalsSplitsOnSpeakerChange() {
        let turns = SpeakerSegmentMerger.mergeFinals([
            seg("a", speaker: 0), seg("b", speaker: 1), seg("c", speaker: 0)
        ])
        XCTAssertEqual(turns.map(\.speaker), [0, 1, 0])
    }

    func testMergeFinalsIgnoresInterim() {
        let turns = SpeakerSegmentMerger.mergeFinals([
            seg("partial", speaker: 0, final: false),
            seg("final", speaker: 0, final: true)
        ])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "final")
    }

    func testGroupWordsSplitsOnSpeakerChange() {
        let words = [
            DiarizedWord(word: "hi", start: 0, end: 0.2, speaker: 0, confidence: nil),
            DiarizedWord(word: "there", start: 0.2, end: 0.4, speaker: 0, confidence: nil),
            DiarizedWord(word: "yo", start: 0.4, end: 0.6, speaker: 1, confidence: nil)
        ]
        let turns = SpeakerSegmentMerger.groupWords(words)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].text, "hi there")
        XCTAssertEqual(turns[0].speaker, 0)
        XCTAssertEqual(turns[1].text, "yo")
        XCTAssertEqual(turns[1].speaker, 1)
    }

    // MARK: - SpeakerRegistry

    private func freshRegistry() -> SpeakerRegistry {
        let suite = UserDefaults(suiteName: "diarization.tests.\(UUID().uuidString)")!
        return SpeakerRegistry(defaults: suite, storageKey: "names")
    }

    func testDefaultDisplayLabels() {
        let r = freshRegistry()
        XCTAssertEqual(r.displayLabel(for: 0), "Speaker 1")
        XCTAssertEqual(r.displayLabel(for: 2), "Speaker 3")
        XCTAssertEqual(r.displayLabel(for: nil), "Speaker")
    }

    func testNamingAndClearing() {
        let r = freshRegistry()
        r.setName("Alice", for: 0)
        XCTAssertEqual(r.displayLabel(for: 0), "Alice")
        r.setName("   ", for: 0)
        XCTAssertEqual(r.displayLabel(for: 0), "Speaker 1", "blank name clears")
    }

    func testColorIndexIsDeterministicAndInRange() {
        let r = freshRegistry()
        for id in 0..<20 {
            let idx = r.colorIndex(for: id)
            XCTAssertEqual(idx, r.colorIndex(for: id))
            XCTAssertTrue((0..<SpeakerRegistry.paletteSize).contains(idx))
        }
        XCTAssertEqual(r.colorIndex(for: nil), 0)
    }

    func testMergeOnSameNameSharesLabelAndColor() {
        let r = freshRegistry()
        r.setName("Bob", for: 0)
        r.setName("Bob", for: 3)
        XCTAssertEqual(r.canonicalId(for: 3), 0)
        XCTAssertEqual(r.displayLabel(for: 3), "Bob")
        XCTAssertEqual(r.colorIndex(for: 3), r.colorIndex(for: 0))
    }

    func testNamesPersistAcrossInstances() {
        let suite = UserDefaults(suiteName: "diarization.tests.\(UUID().uuidString)")!
        SpeakerRegistry(defaults: suite, storageKey: "names").setName("Carol", for: 1)
        let reloaded = SpeakerRegistry(defaults: suite, storageKey: "names")
        XCTAssertEqual(reloaded.displayLabel(for: 1), "Carol")
        XCTAssertEqual(reloaded.namedSpeakerIds, [1])
    }

    // MARK: - Speaker chips (BM P7)

    func testNoChipWithoutSpeakerId() {
        // The diarization-off / single-speaker path never sets a speaker id
        // (`finalizeCaption` defaults it to nil) — those captions get no chip.
        XCTAssertNil(SpeakerChipModel.chip(speaker: nil, registry: freshRegistry()))
        let entry = AmbientCaptionService.CaptionEntry(text: "hello", timestamp: Date(), seq: 1)
        XCTAssertNil(SpeakerChipModel.chip(speaker: entry.speaker, registry: freshRegistry()))
    }

    func testChipForUnnamedSpeakerShowsDefaultLabelAndStableColor() {
        let r = freshRegistry()
        let chip = SpeakerChipModel.chip(speaker: 1, registry: r)
        XCTAssertEqual(chip, SpeakerChip(speakerId: 1, label: "Speaker 2", colorIndex: r.colorIndex(for: 1)))
    }

    func testChipRenameRoundTripsThroughRegistry() {
        let suite = UserDefaults(suiteName: "diarization.tests.\(UUID().uuidString)")!
        let r = SpeakerRegistry(defaults: suite, storageKey: "names")
        XCTAssertEqual(SpeakerChipModel.chip(speaker: 0, registry: r)?.label, "Speaker 1")

        // The chip's tap-to-name action writes through the registry…
        r.setName("Alice", for: 0)
        XCTAssertEqual(SpeakerChipModel.chip(speaker: 0, registry: r)?.label, "Alice")

        // …persists across a relaunch…
        let reloaded = SpeakerRegistry(defaults: suite, storageKey: "names")
        XCTAssertEqual(SpeakerChipModel.chip(speaker: 0, registry: reloaded)?.label, "Alice")

        // …and clearing reverts to the default label.
        reloaded.setName(nil, for: 0)
        XCTAssertEqual(SpeakerChipModel.chip(speaker: 0, registry: reloaded)?.label, "Speaker 1")
    }

    func testChipsMergeOnSameName() {
        let r = freshRegistry()
        r.setName("Bob", for: 0)
        r.setName("Bob", for: 5)
        let merged = SpeakerChipModel.chip(speaker: 5, registry: r)
        XCTAssertEqual(merged?.label, "Bob")
        XCTAssertEqual(merged?.colorIndex, SpeakerChipModel.chip(speaker: 0, registry: r)?.colorIndex)
    }

    // MARK: - PCMConverter

    func testDownmixAveragesChannels() {
        let mono = PCMConverter.downmixToMono([[1.0, -1.0], [0.0, 1.0]])
        XCTAssertEqual(mono, [0.5, 0.0])
    }

    func testLinear16ClampsAndScales() {
        let data = PCMConverter.linear16(fromMono: [0, 1.0, -1.0, 2.0])
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], Int16.max)
        XCTAssertEqual(samples[2], -Int16.max)        // -32767, symmetric scaling
        XCTAssertEqual(samples[3], Int16.max, "over-unity is clamped, not wrapped")
    }

    func testLinear16ByteCountMatchesSampleCount() {
        let data = PCMConverter.linear16(fromMono: [0.1, 0.2, 0.3])
        XCTAssertEqual(data.count, 3 * MemoryLayout<Int16>.size)
    }

    // MARK: - Fallback contract

    func testSingleSpeakerAdapterEmitsUnlabeledSegment() {
        let segment = SingleSpeakerAdapter.segment(forTranscript: "no labels here", isFinal: true)
        XCTAssertNil(segment?.speaker, "fallback path must never assign a speaker")
        XCTAssertEqual(segment?.text, "no labels here")
        XCTAssertNil(SingleSpeakerAdapter.segment(forTranscript: "   ", isFinal: true))
    }
}
