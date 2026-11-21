import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan MO P1: what a live-hints session must never do, and the shapes it hands the rest of the
/// app — the idle audio session, the recogniser's words, the feature inventory's record.
@MainActor
final class LiveHintsGuardTests: XCTestCase {

    // MARK: - Nothing is written

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Code with comments and string literals removed, as `CaptionSessionIsolationTests` reads it.
    private static func code(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return text
    }

    func testTheSessionNamesNoStoreThatKeepsWhatWasSaid() throws {
        let folder = Self.sourcesRoot.appendingPathComponent("Services/LiveHints")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "sanity: the live-hints sources were found")
        let forbidden = [
            "ConversationStore", "BrainStore", "SemanticMemoryStore", "UserMemory", "MemoryLoopService",
            "SpeakerRegistry", "setName", "CaptionSessionStore", "SavedNotesStore", "UserDefaults",
            "FileManager", "JSONStore", "write(to", "Spotlight", "CSSearchableItem",
        ]
        for url in files {
            let code = try Self.code(url)
            for name in forbidden {
                XCTAssertFalse(code.contains(name), "\(url.lastPathComponent) names \(name): hints are never written")
            }
        }
    }

    func testTheWearersVoiceIsNeverWrittenToTheSpeakerNames() async {
        let suiteName = "LiveHintsGuardTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let registry = SpeakerRegistry(defaults: suite, storageKey: "names")
        let before = suite.dictionaryRepresentation().filter { $0.key == "names" }.count

        let captions = FakeHintCaptions()
        let clock = FakeHintClock(now: Date())
        let service = LiveHintsService(carriers: .init(
            captions: captions, documents: FakeHintDocuments(), model: FakeHintModel(), lens: FakeHintLens(),
            ear: FakeHintEar(), voiceActivity: FakeHintVoiceActivity(), phoneList: LiveHintsPhoneList(),
            clock: clock, allowance: FakeHintAllowance()))
        service.isEnabled = { true }
        service.firstRunAcknowledged = { true }
        service.start()
        service.markWearer(speaker: 0)
        captions.say("What's the warranty on the compressor?", speaker: 1)
        captions.say("I think it's twelve weeks, isn't it?", speaker: 0)
        await service.waitUntilIdle()
        service.stop()

        XCTAssertEqual(suite.dictionaryRepresentation().filter { $0.key == "names" }.count, before)
        XCTAssertNil(registry.name(for: 0))
        XCTAssertNil(service.wearerSpeaker, "the tap goes with the session")
    }

    func testSpeakerIdentificationIsStillNotBiometric() {
        let note = AIFeature.speakerIdentification.record.screeningNote ?? ""
        XCTAssertTrue(note.contains("no voiceprint, embedding or cross-session voice match exists"))
        XCTAssertEqual(AIFeature.speakerIdentification.record.sensitiveCategories, [.none])
    }

    // MARK: - The inventory

    func testLiveHintsIsInTheInventoryScreenedNoneAndStoringNothing() {
        let record = AIFeature.liveHints.record
        XCTAssertEqual(record.sensitiveCategories, [.none])
        XCTAssertEqual(record.disableSwitch.key, "liveHintsEnabled")
        XCTAssertFalse(record.disableSwitch.preexisting)
        XCTAssertTrue(record.stores.isEmpty)
        XCTAssertTrue(record.toolNames.isEmpty)
        XCTAssertTrue(record.dataRetainedWhenDisabled.hasPrefix("Nothing"))
        XCTAssertFalse(record.erasure.isAvailable)
        XCTAssertNotNil(record.screeningNote)
    }

    func testSwitchedOffTheGateSaysSo() {
        let key = AIFeature.liveHints.record.disableSwitch.key
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        Config.liveHintsEnabled = false
        XCTAssertFalse(AIFeatureGate.isEnabled(.liveHints))
        Config.liveHintsEnabled = true
        XCTAssertTrue(AIFeatureGate.isEnabled(.liveHints))
    }

    func testTheCaptureNoticeIsExactlyThePlansLine() {
        XCTAssertEqual(LiveHintsCopy.captureNotice,
                       "Live hints listens to everyone near you. Tell people you're using it.")
    }

    // MARK: - The audio session (§6–§7)

    private func inputs(hints: Bool, consumer: Bool = false, wakeMic: WakeListenMic = .iPhone,
                        route: MicRoute = .glasses, listening: Bool = true, carPlay: Bool = false,
                        foreign: Bool = false) -> WakeListenPolicy.Inputs {
        WakeListenPolicy.Inputs(listeningEnabled: listening, silentMode: false, carPlayMode: carPlay,
                                foreignOwner: foreign, wearerAudioConsumerActive: consumer,
                                wakeListenMic: wakeMic, micRoute: route, liveHintsActive: hints)
    }

    func testAHintsSessionListensOnThePhoneInTheHintsShape() {
        let plan = WakeListenPolicy.decide(inputs(hints: true))
        XCTAssertEqual(plan.listen, .phone)
        XCTAssertTrue(plan.hintsShape)
        XCTAssertEqual(plan.mode, .spokenAudio)
        XCTAssertEqual(plan.preferredInput, .phone, "the built-in mic, preferred explicitly")
        XCTAssertTrue(plan.categoryOptions.contains(.duckOthers))
        XCTAssertTrue(plan.categoryOptions.contains(.allowBluetoothA2DP))
        XCTAssertFalse(plan.categoryOptions.contains(.allowBluetoothHFP), "never the glasses' call mode")
    }

    func testTheHintsShapeOutranksACaptionConsumersHoldAndTheIdleChoice() {
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: false, consumer: true)).listen, .bluetooth(.glasses))
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true, consumer: true)).listen, .phone)
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true, wakeMic: .sameAsMicrophone)).listen, .phone)
    }

    func testTheHintsShapeNeverTakesSomeoneElsesSessionOrTheCar() {
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true, listening: false)).listen, .off)
        XCTAssertEqual(WakeListenPolicy.decide(inputs(hints: true, foreign: true)).listen, .notOurs)
        let car = WakeListenPolicy.decide(inputs(hints: true, carPlay: true))
        XCTAssertEqual(car.listen, .carPlay)
        XCTAssertFalse(car.hintsShape)
        XCTAssertEqual(car.mode, .voiceChat)
    }

    func testWithoutASessionTheIdleShapeIsUnchanged() {
        let plan = WakeListenPolicy.decide(inputs(hints: false))
        XCTAssertFalse(plan.hintsShape)
        XCTAssertEqual(plan.mode, .default)
        XCTAssertEqual(plan.categoryOptions, [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
    }

    // MARK: - The recogniser's words (§8)

    func testKeywordsLeadAndDocumentTitlesFollowTheVaults() {
        let input = DictationVocabulary.Input(
            vaults: [VaultManifest(id: "v", name: "Rooftop", version: "1", files: [], documents: [])],
            wakePhrases: ["hey there"],
            keywords: ["Tecumseh", "warranty"],
            documentTitles: ["Service terms", "warranty"])
        XCTAssertEqual(DictationVocabulary.build(input), ["Tecumseh", "warranty", "Rooftop", "Service terms", "hey there"])
    }

    func testWithoutHintsTheVocabularyIsUnchanged() {
        let input = DictationVocabulary.Input(wakePhrases: ["hey there"])
        XCTAssertEqual(DictationVocabulary.build(input), ["hey there"])
    }
}
