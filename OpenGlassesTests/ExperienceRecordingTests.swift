import XCTest
@testable import OpenGlasses

/// Plan IM P1 — "Record experience": the store's lifecycle, erasure and redaction; the spoken
/// markers; the recorder's session (standing line, car prompts, next case, the ten-minute cap, the
/// open-job path); who is offered it (Medical Compliance, the capability); and the car's row.
///
/// Headless: a scripted capture stands in for the microphone and the recogniser, every store is
/// over a temporary directory, and nothing touches a `.shared` service's audio.
@MainActor
final class ExperienceRecordingStoreTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExperienceRecordingStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func audioFile(_ name: String = UUID().uuidString) -> URL {
        let url = root.appendingPathComponent("\(name).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 7, count: 64))
        return url
    }

    private func recording(_ transcript: String = "The rooftop unit's board throws E7 after rain",
                           at date: Date = Date(), status: ExperienceRecording.Status = .recorded) -> ExperienceRecording {
        ExperienceRecording(createdAt: date, duration: 75, transcript: transcript, redactions: [],
                            vaultId: "refrigeration", status: status)
    }

    func testARecordingAndItsAudioSurviveAReopen() throws {
        let store = ExperienceRecordingStore(directory: root)
        let kept = recording()
        store.add(kept, audioFrom: audioFile())
        XCTAssertTrue(store.hasAudio(kept.id))

        let reopened = ExperienceRecordingStore(directory: root)
        XCTAssertEqual(reopened.recordings, [kept])
        XCTAssertTrue(reopened.hasAudio(kept.id))
        XCTAssertEqual(reopened.recordings.first?.status, .recorded)
    }

    func testStatusOnlyMovesForward() {
        let store = ExperienceRecordingStore(directory: root)
        let kept = recording()
        store.add(kept)
        XCTAssertFalse(store.advance(id: kept.id, to: .recorded), "a repeat is not a move")
        XCTAssertTrue(store.advance(id: kept.id, to: .sent))
        XCTAssertTrue(store.advance(id: kept.id, to: .drafted))
        XCTAssertFalse(store.advance(id: kept.id, to: .sent), "a drafted recording cannot become unsent")
        XCTAssertTrue(store.advance(id: kept.id, to: .reviewed))
        XCTAssertFalse(store.advance(id: "missing", to: .sent))
        XCTAssertEqual(ExperienceRecordingStore(directory: root).recording(id: kept.id)?.status, .reviewed)
    }

    func testDeleteAndRemoveAllTakeTheAudioToo() {
        let store = ExperienceRecordingStore(directory: root)
        let first = recording("first"), second = recording("second")
        store.add(first, audioFrom: audioFile())
        store.add(second, audioFrom: audioFile())
        store.delete(id: first.id)
        XCTAssertFalse(store.hasAudio(first.id))
        XCTAssertEqual(store.recordings.map(\.id), [second.id])

        store.removeAll()
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(store.hasAudio(second.id))
        XCTAssertTrue(ExperienceRecordingStore(directory: root).recordings.isEmpty)
    }

    /// Decision 2: the audio goes 30 days after the recording; the transcript stays.
    func testAudioIsDeletedAfterThirtyDaysAndTheTranscriptStays() {
        let now = Date()
        let store = ExperienceRecordingStore(directory: root, now: now)
        let old = recording("old", at: now.addingTimeInterval(-ExperienceRecorderRules.audioRetention - 60))
        let fresh = recording("fresh", at: now.addingTimeInterval(-ExperienceRecorderRules.audioRetention + 3600))
        store.add(old, audioFrom: audioFile())
        store.add(fresh, audioFrom: audioFile())

        XCTAssertEqual(store.sweepExpiredAudio(now: now), 1)
        XCTAssertFalse(store.hasAudio(old.id))
        XCTAssertTrue(store.hasAudio(fresh.id))
        XCTAssertEqual(store.recording(id: old.id)?.transcript, "old")
        XCTAssertNotNil(store.recording(id: old.id)?.audioDeletedAt)
        XCTAssertNil(store.recording(id: fresh.id)?.audioDeletedAt)
        XCTAssertEqual(store.sweepExpiredAudio(now: now), 0, "a second sweep finds nothing")

        // Opening the store sweeps too.
        let later = now.addingTimeInterval(2 * 3600)
        let reopened = ExperienceRecordingStore(directory: root, now: later)
        XCTAssertFalse(reopened.hasAudio(fresh.id))
        XCTAssertTrue(ExperienceRecorderCopy.audioLine(reopened.recording(id: fresh.id)!, hasAudio: false)
            .contains("deleted"))
    }

    func testAudioNoRecordingNamesIsRemoved() throws {
        let store = ExperienceRecordingStore(directory: root)
        try FileManager.default.createDirectory(at: store.audioLocation, withIntermediateDirectories: true)
        let stray = store.audioLocation.appendingPathComponent("orphan.m4a")
        FileManager.default.createFile(atPath: stray.path, contents: Data([1]))
        XCTAssertEqual(store.sweepExpiredAudio(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testTheCapEvictsReviewedRecordingsFirst() {
        let store = ExperienceRecordingStore(directory: root)
        let base = Date().addingTimeInterval(-100_000)
        let reviewed = recording("reviewed", at: base.addingTimeInterval(50), status: .reviewed)
        let oldest = recording("oldest", at: base)
        store.add(oldest)
        store.add(reviewed)
        for index in 0..<(ExperienceRecorderRules.entryCap - 1) {
            store.add(recording("case \(index)", at: base.addingTimeInterval(Double(100 + index))))
        }
        XCTAssertEqual(store.recordings.count, ExperienceRecorderRules.entryCap)
        XCTAssertNil(store.recording(id: reviewed.id), "a reviewed recording makes room first")
        XCTAssertNotNil(store.recording(id: oldest.id))
    }

    // MARK: - Erasure and the registry

    func testTheSubjectErasureRemovesARecordingThatNamesThePersonWithItsAudio() async {
        let store = ExperienceRecordingStore(directory: root)
        let named = recording("Out at Mereana Tukino's the fan seized")
        let other = recording("The fan seized after a power cut")
        store.add(named, audioFrom: audioFile())
        store.add(other, audioFrom: audioFile())

        var stores = SubjectErasureCoordinator.Stores()
        stores.experienceRecordings = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("Mereana Tukino"))
        let receipt = receipts.first { $0.store == .experienceRecordings }
        XCTAssertEqual(receipt?.localComplete, true)
        XCTAssertNil(store.recording(id: named.id))
        XCTAssertFalse(store.hasAudio(named.id))
        XCTAssertNotNil(store.recording(id: other.id))
        XCTAssertNil(ExperienceRecordingStore(directory: root).recording(id: named.id))
    }

    func testTheRegistryDescribesTheStoreLikeTheCandidates() {
        let record = SensitiveStore.experienceRecordings.record
        XCTAssertEqual(record.subjectLinkage, .thirdPartySubject)
        XCTAssertTrue(record.backupExcluded)
        XCTAssertEqual(record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(ExperienceRecordingStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.experienceRecordings))
        XCTAssertEqual(record.subjectLinkage, SensitiveStore.learningCandidates.record.subjectLinkage)
        XCTAssertEqual(record.backupExcluded, SensitiveStore.learningCandidates.record.backupExcluded)
    }

    func testAudioAndIndexAreKeptOutOfBackup() throws {
        let store = ExperienceRecordingStore(directory: root)
        let kept = recording()
        store.add(kept, audioFrom: audioFile())
        for url in [store.fileLocation, store.audioLocation, store.audioURL(for: kept.id)] {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, url.lastPathComponent)
        }
    }

    /// Leaving the organisation clears the store where the candidates are cleared.
    func testLeavingTheOrganisationClearsItBesideTheCandidates() throws {
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenGlasses/Sources/App/OpenGlassesApp.swift"),
                             encoding: .utf8)
        let candidates = try XCTUnwrap(app.range(of: "LearningCandidateStore.shared.removeAll()"))
        let recordings = try XCTUnwrap(app.range(of: "ExperienceRecordingStore.shared.removeAll()"))
        let window = app[candidates.upperBound..<recordings.lowerBound]
        XCTAssertLessThan(window.count, 200, "cleared in the same departure step as the candidates")
        XCTAssertEqual(app.components(separatedBy: "erasure.experienceRecordings = ExperienceRecordingStore.shared").count, 2)
        XCTAssertEqual(app.components(separatedBy: "erasureStores.experienceRecordings = ExperienceRecordingStore.shared").count, 2)
    }
}

// MARK: - The transcript

final class ExperienceTranscriptTests: XCTestCase {

    func testSecretsAndContactDetailsAreRedactedAtCapture() {
        let cleaned = ExperienceTranscript.clean(
            "Call me on sam.tane@example.com about the unit, the key is sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(cleaned.text.contains("sam.tane@example.com"))
        XCTAssertFalse(cleaned.text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(cleaned.redactions.isEmpty)
        let order = SecretPatterns.all.map(\.name)
        let positions = cleaned.redactions.compactMap { order.firstIndex(of: $0) }
        XCTAssertEqual(positions, positions.sorted(), "redactions are named in SecretPatterns order")
    }

    func testWhitespaceAndControlCharactersAreFlattened() {
        let cleaned = ExperienceTranscript.clean("  the fan\u{0007}  seized \u{202E}after\n\nrain ")
        XCTAssertEqual(cleaned.text, "the fan seized after rain")
        XCTAssertTrue(cleaned.redactions.isEmpty)
    }

    func testATranscriptIsBoundedAtTheLimit() {
        let long = String(repeating: "word ", count: ExperienceRecorderRules.transcriptLimit)
        XCTAssertEqual(ExperienceTranscript.clean(long).text.count, ExperienceRecorderRules.transcriptLimit)
    }

    func testAShortTranscriptIsOneFinding() {
        XCTAssertEqual(ExperienceTranscript.findingParts("The fan seized."), ["The fan seized."])
        XCTAssertEqual(ExperienceTranscript.findingParts(""), [])
    }

    func testALongTranscriptIsSplitIntoPartsThatEachFitAndLoseNothing() {
        let sentence = "The condenser fan on the rooftop unit seizes after a wet night, so check the bearing first. "
        let text = String(repeating: sentence, count: 60).trimmingCharacters(in: .whitespaces)
        let parts = ExperienceTranscript.findingParts(text)
        XCTAssertGreaterThan(parts.count, 1)
        for (index, part) in parts.enumerated() {
            XCTAssertLessThanOrEqual(part.unicodeScalars.count, LearningCandidateText.findingLimit)
            XCTAssertTrue(part.hasPrefix("Part \(index + 1) of \(parts.count): "), part)
            if case .failure(let refusal) = LearningCandidateText.clean(finding: part, symptom: nil, fix: nil) {
                XCTFail("part \(index + 1) would be refused: \(refusal)")
            }
        }
        let rejoined = parts.map { $0.replacingOccurrences(of: #"^Part \d+ of \d+: "#, with: "", options: .regularExpression) }
            .joined(separator: " ")
        XCTAssertEqual(rejoined.split(separator: " "), text.split(separator: " "), "nothing is dropped")
    }

    func testPartsAreMeasuredInScalarsNotCharacters() {
        // Each flag is one character and two scalars.
        let text = String(repeating: "🇳🇿 ", count: 1500)
        for part in ExperienceTranscript.findingParts(text) {
            XCTAssertLessThanOrEqual(part.unicodeScalars.count, LearningCandidateText.findingLimit)
        }
    }
}

// MARK: - The spoken markers

final class ExperienceRecordingMarkersTests: XCTestCase {

    func testThatsOneNextCaseEndsTheCaseWhereverItIsSaid() {
        let split = ExperienceRecordingMarkers.split("and a new board fixed it. That's one, next case. The other one is a Brightline")
        XCTAssertEqual(split.marker, .nextCase)
        XCTAssertEqual(split.before, "and a new board fixed it")
        XCTAssertEqual(split.after, "The other one is a Brightline")
    }

    func testTheMarkerAloneOrWithAFillerOpensNothing() {
        for stretch in ["That's one, next case.", "Okay, that's one. Next case.", "that is 1 next case",
                        "Next case.", "okay next case", "New case"] {
            let split = ExperienceRecordingMarkers.split(stretch)
            XCTAssertEqual(split.marker, .nextCase, stretch)
            XCTAssertEqual(split.before, "", stretch)
            XCTAssertEqual(split.after, "", stretch)
        }
    }

    func testNextCaseInsideASentenceIsSpeech() {
        for stretch in ["In the next case I'd check the board first",
                        "the next case we had was worse", "that one, the next case of it"] {
            let split = ExperienceRecordingMarkers.split(stretch)
            XCTAssertNil(split.marker, stretch)
            XCTAssertEqual(split.before, stretch)
        }
    }

    func testAMarkerThatIsTheLastSentenceEndsTheCase() {
        let finish = ExperienceRecordingMarkers.split("Dried the outdoor board and sealed the cover. That's all.")
        XCTAssertEqual(finish.marker, .finish)
        XCTAssertEqual(finish.before, "Dried the outdoor board and sealed the cover")
        let next = ExperienceRecordingMarkers.split("A new capacitor sorted it. Okay, next case.")
        XCTAssertEqual(next.marker, .nextCase)
        XCTAssertEqual(next.before, "A new capacitor sorted it")
        for stretch in ["The fan was the problem, that's all.", "Dried the board. That's all it needed."] {
            XCTAssertNil(ExperienceRecordingMarkers.split(stretch).marker, stretch)
        }
    }

    func testFinishOnlyAsTheWholeStretchOrItsLastSentence() {
        for stretch in ["That's all.", "Okay, that's everything, thanks", "Stop recording", "I'm done",
                        "That's one, that's all."] {
            XCTAssertEqual(ExperienceRecordingMarkers.split(stretch).marker, .finish, stretch)
        }
        for stretch in ["and that's all it needed", "I'm done with the board, then the fan"] {
            XCTAssertNil(ExperienceRecordingMarkers.split(stretch).marker, stretch)
        }
    }

    func testAFinishStraightAfterTheMarkerEndsTheSession() {
        let split = ExperienceRecordingMarkers.split("New capacitor fixed it. That's one, next case. That's all.")
        XCTAssertEqual(split.marker, .finish)
        XCTAssertEqual(split.before, "New capacitor fixed it")
    }

    func testATranscriptSplitsIntoItsCases() {
        let stretches = [
            "An Acme RX-200 with E7 after rain.",
            "Dried the outdoor board, sealed the cover. That's one, next case. A Brightline that short cycles",
            "a dirty filter was all it was",
            "next case",
            "That's all",
            "said after the end",
        ]
        XCTAssertEqual(ExperienceRecordingMarkers.cases(in: stretches), [
            "An Acme RX-200 with E7 after rain. Dried the outdoor board, sealed the cover",
            "A Brightline that short cycles a dirty filter was all it was",
        ])
    }

    // MARK: Translated markers (owner decision 2026-11-27)

    /// A recogniser locale for each of the table's keys, as a phone in that language reports it.
    private static let localeForKey: [String: String] = [
        "ar": "ar-SA", "es": "es-MX", "fr": "fr-CA", "hu": "hu-HU", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
        "nl": "nl-NL", "pt": "pt-BR", "ru": "ru-RU", "ur": "ur-PK", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
    ]

    /// How each language's recogniser ends a sentence, and whether it spaces after one.
    private static func sentenceEnd(_ key: String) -> String {
        switch key {
        case "ja", "zh-Hans", "zh-Hant": return "。"
        case "ur": return "۔ "
        default: return ". "
        }
    }

    func testEveryLanguageHasItsThreePhrasesAndTheLongOneEndsWithTheBareOne() {
        XCTAssertEqual(Set(ExperienceRecordingMarkers.translations.keys), Set(Self.localeForKey.keys))
        for (key, translation) in ExperienceRecordingMarkers.translations {
            let phrases = translation.phrases
            XCTAssertTrue(phrases.nextCase.hasSuffix(phrases.bareNextCase), key)
            XCTAssertEqual(ExperienceRecordingMarkers.key(for: Locale(identifier: Self.localeForKey[key]!)), key)
            XCTAssertEqual(ExperienceRecordingMarkers.phrases(for: Locale(identifier: Self.localeForKey[key]!)), phrases)
        }
    }

    func testTheLocaleChoosesItsLanguageAndAnythingElseIsEnglish() {
        let cases: [String: String?] = [
            "es-ES": "es", "es_US": "es", "fr-FR": "fr", "pt-PT": "pt", "zh-Hans-CN": "zh-Hans", "zh-Hant": "zh-Hant",
            "zh-HK": "zh-Hant", "zh_CN": "zh-Hans", "en-US": nil, "en-GB": nil, "de-DE": nil, "yue-CN": nil,
        ]
        for (identifier, key) in cases {
            XCTAssertEqual(ExperienceRecordingMarkers.key(for: Locale(identifier: identifier)), key, identifier)
        }
        XCTAssertEqual(ExperienceRecordingMarkers.phrases(for: Locale(identifier: "de-DE")), ExperienceRecordingMarkers.english)
    }

    /// Each language's three phrases split and end a case as English's do: the long marker
    /// anywhere, the bare one and the finish as the whole stretch or its last sentence, a finish
    /// straight after the long marker ending the session.
    func testEachLanguagesPhrasesSplitAndEndACase() {
        for (key, translation) in ExperienceRecordingMarkers.translations {
            let listening = ExperienceRecordingMarkers.Listening.language(Locale(identifier: Self.localeForKey[key]!))
            let phrases = translation.phrases
            let end = Self.sentenceEnd(key)
            func split(_ text: String) -> ExperienceRecordingMarkers.Split {
                ExperienceRecordingMarkers.split(text, listening: listening)
            }

            let long = split("RX-200 E7" + end + phrases.nextCase + end + "RX-300")
            XCTAssertEqual(long.marker, .nextCase, key)
            XCTAssertEqual(long.before, "RX-200 E7", key)
            XCTAssertEqual(long.after, "RX-300", key)
            // Said with no pause and no sentence end before it, still a marker.
            let joined = split("RX-200 E7 " + phrases.nextCase + " RX-300")
            XCTAssertEqual(joined.marker, .nextCase, key)
            XCTAssertEqual(joined.after, "RX-300", key)

            for alone in [phrases.nextCase, phrases.nextCase + end, phrases.bareNextCase, phrases.bareNextCase + end,
                          "Okay, " + phrases.bareNextCase] {
                let split = split(alone)
                XCTAssertEqual(split.marker, .nextCase, "\(key): \(alone)")
                XCTAssertEqual(split.before, "", "\(key): \(alone)")
                XCTAssertEqual(split.after, "", "\(key): \(alone)")
            }
            let bareLast = split("RX-200 E7" + end + phrases.bareNextCase + end)
            XCTAssertEqual(bareLast.marker, .nextCase, key)
            XCTAssertEqual(bareLast.before, "RX-200 E7", key)

            XCTAssertEqual(split(phrases.finish).marker, .finish, key)
            XCTAssertEqual(split(phrases.finish + end).marker, .finish, key)
            let finishLast = split("RX-200 E7" + end + phrases.finish + end)
            XCTAssertEqual(finishLast.marker, .finish, key)
            XCTAssertEqual(finishLast.before, "RX-200 E7", key)
            let longThenFinish = split("RX-200 E7" + end + phrases.nextCase + end + phrases.finish + end)
            XCTAssertEqual(longThenFinish.marker, .finish, key)
            XCTAssertEqual(longThenFinish.before, "RX-200 E7", key)

            XCTAssertEqual(ExperienceRecordingMarkers.cases(in: ["RX-200 E7" + end + phrases.nextCase,
                                                                 "RX-300 F2", phrases.finish, "RX-400"],
                                                            listening: listening),
                           ["RX-200 E7", "RX-300 F2"], key)
        }
    }

    /// English is always accepted, whatever language the phone transcribes in.
    func testEnglishStillWorksUnderEveryLocale() {
        for identifier in Self.localeForKey.values.sorted() + ["en-US", "de-DE"] {
            let listening = ExperienceRecordingMarkers.Listening.language(Locale(identifier: identifier))
            let next = ExperienceRecordingMarkers.split("and a new board fixed it. That's one, next case. The other one",
                                                        listening: listening)
            XCTAssertEqual(next.marker, .nextCase, identifier)
            XCTAssertEqual(next.before, "and a new board fixed it", identifier)
            XCTAssertEqual(next.after, "The other one", identifier)
            XCTAssertEqual(ExperienceRecordingMarkers.split("Okay, next case.", listening: listening).marker, .nextCase, identifier)
            XCTAssertEqual(ExperienceRecordingMarkers.split("Sealed the cover. That's all.", listening: listening).marker,
                           .finish, identifier)
            XCTAssertEqual(ExperienceRecordingMarkers.split("Stop recording", listening: listening).marker, .finish, identifier)
            XCTAssertNil(ExperienceRecordingMarkers.split("and that's all it needed", listening: listening).marker, identifier)
        }
    }

    /// The recogniser writes a phrase in its own way: case, punctuation, apostrophes, spaces,
    /// ё/е, Arabic vowel marks, "1" for one, Japanese and Chinese run together, Korean spaced oddly.
    func testWhatTheRecogniserWritesStillMatches() {
        func marker(_ text: String, _ identifier: String) -> ExperienceRecordingMarkers.Marker? {
            ExperienceRecordingMarkers.split(text, listening: .language(Locale(identifier: identifier))).marker
        }
        XCTAssertEqual(marker("ESA ES UNA SIGUIENTE CASO", "es-MX"), .nextCase)
        XCTAssertEqual(marker("Esa es 1, siguiente caso", "es-MX"), .nextCase)
        XCTAssertEqual(marker("¡Eso es todo!", "es-MX"), .finish)
        XCTAssertEqual(marker("C\u{2019}est tout.", "fr-CA"), .finish)
        XCTAssertEqual(marker("c est tout", "fr-CA"), nil, "a split word is not the phrase")
        XCTAssertEqual(marker("Ça   en fait un ,  cas suivant", "fr-CA"), .nextCase)
        XCTAssertEqual(marker("Это все.", "ru-RU"), .finish, "ё written as е")
        XCTAssertEqual(marker("Это ВСЁ", "ru-RU"), .finish)
        XCTAssertEqual(marker("это 1, следующий случай", "ru-RU"), .nextCase)
        XCTAssertEqual(marker("Dat is er een, volgend geval", "nl-NL"), .nextCase)
        XCTAssertEqual(marker("هَذَا كُلُّ شَيْءٍ", "ar-SA"), .finish, "vowel marks")
        XCTAssertEqual(marker("هذه واحدة الحالة التالية؟", "ar-SA"), .nextCase)
        XCTAssertEqual(marker("بس اتنا ہی۔", "ur-PK"), .finish)
        XCTAssertEqual(marker("یہ ایک ہو گیا اگلا کیس", "ur-PK"), .nextCase)
        XCTAssertEqual(marker("これで一件次のケース", "ja-JP"), .nextCase, "no punctuation")
        XCTAssertEqual(marker("これで１件、次のケース。", "ja-JP"), .nextCase, "a full-width digit")
        XCTAssertEqual(marker("以上です。", "ja-JP"), .finish)
        XCTAssertEqual(marker("这是1个，下一个案例", "zh-CN"), .nextCase)
        XCTAssertEqual(marker("下一个 案例", "zh-CN"), .nextCase, "a stray space")
        XCTAssertEqual(marker("就這些。", "zh-TW"), .finish)
        XCTAssertEqual(marker("이걸로하나 다음사례", "ko-KR"), .nextCase, "Korean spaced differently")
        XCTAssertEqual(marker("이상 입니다.", "ko-KR"), .finish)

        // CJK with no spaces at all: the case's words either side come back exactly as said.
        let japanese = ExperienceRecordingMarkers.split("ファンを交換しました。これで一件、次のケース。冷蔵庫の扉が", listening:
            .language(Locale(identifier: "ja-JP")))
        XCTAssertEqual(japanese.marker, .nextCase)
        XCTAssertEqual(japanese.before, "ファンを交換しました")
        XCTAssertEqual(japanese.after, "冷蔵庫の扉が")
        let chinese = ExperienceRecordingMarkers.split("更换了风扇。就这些。", listening: .language(Locale(identifier: "zh-CN")))
        XCTAssertEqual(chinese.marker, .finish)
        XCTAssertEqual(chinese.before, "更换了风扇")
    }

    /// The finish rule holds in every language: only the whole stretch or its last sentence.
    func testAFinishInsideASentenceStaysInTheCase() {
        let negatives: [(String, String)] = [
            ("Eso es todo lo que necesitaba.", "es-MX"),
            ("Cambié la placa, eso es todo", "es-MX"),
            ("C'est tout ce qu'il fallait.", "fr-CA"),
            ("Это всё, что было нужно.", "ru-RU"),
            ("就这些问题。", "zh-CN"),
            ("以上ですか", "ja-JP"),
            ("En el siguiente caso revisaría la placa", "es-MX"),
            ("Im volgend geval controleer ik het bord", "nl-NL"),
        ]
        for (text, identifier) in negatives {
            let split = ExperienceRecordingMarkers.split(text, listening: .language(Locale(identifier: identifier)))
            XCTAssertNil(split.marker, "\(identifier): \(text)")
            XCTAssertEqual(split.before, text, "\(identifier): \(text)")
        }
    }

    /// The phone's language is the one listened for, beside English: an English phone does not
    /// hear Spanish, and the drafting pass, which cannot know, hears every language.
    func testOnlyTheRecordingsLanguageIsHeardBesideEnglish() {
        XCTAssertNil(ExperienceRecordingMarkers.split("Eso es todo.").marker)
        XCTAssertNil(ExperienceRecordingMarkers.split("Eso es todo.", listening: .language(Locale(identifier: "fr-FR"))).marker)
        XCTAssertEqual(ExperienceRecordingMarkers.split("Eso es todo.", listening: .everyLanguage).marker, .finish)
        XCTAssertEqual(ExperienceRecordingMarkers.split("就這些", listening: .everyLanguage).marker, .finish)
        XCTAssertEqual(ExperienceRecordingMarkers.split("That's all.", listening: .everyLanguage).marker, .finish)
    }

    /// The copy names the phrases the recorder listens for, in the phone's speech language; the
    /// English copy reads exactly as it did.
    func testTheCopyNamesTheLanguagesOwnPhrasesAndEnglishIsUnchanged() {
        let english = Locale(identifier: "en-US")
        XCTAssertEqual(ExperienceRecorderCopy.cardHowTo(speaking: english),
                       "Say \u{201C}that's one, next case\u{201D} to start the next, or \u{201C}that's all\u{201D} to finish. Each recording stops at ten minutes.")
        XCTAssertEqual(ExperienceRecorderCopy.carPlayPrompts(speaking: english),
                       "One case per recording. Say the equipment, its brand and model if you know it. The kind of site, if it matters. The problem as it showed up. What you checked and tried. And what fixed it, and how sure you are. Say \u{201C}that's one, next case\u{201D} to start the next, or \u{201C}that's all\u{201D} to finish.")
        XCTAssertEqual(ExperienceRecorderCopy.recordHint(speaking: english),
                       "Records one case. Say \u{201C}that's one, next case\u{201D} to start the next.")
        for (key, identifier) in Self.localeForKey {
            let phrases = ExperienceRecordingMarkers.translations[key]!.phrases
            let locale = Locale(identifier: identifier)
            for copy in [ExperienceRecorderCopy.cardHowTo(speaking: locale), ExperienceRecorderCopy.carPlayPrompts(speaking: locale)] {
                XCTAssertTrue(copy.contains(phrases.nextCase), key)
                XCTAssertTrue(copy.contains(phrases.finish), key)
                XCTAssertFalse(copy.contains("that's one, next case"), key)
            }
            XCTAssertTrue(ExperienceRecorderCopy.recordHint(speaking: locale).contains(phrases.nextCase), key)
        }
    }
}

// MARK: - Who is offered it

@MainActor
final class ExperienceRecordingAvailabilityTests: XCTestCase {

    private func verdict(hipaa: Bool = false, fieldAssist: Bool = true,
                         _ capability: FieldAssistCapabilityCheck) -> ExperienceRecordingAvailability.Verdict {
        ExperienceRecordingAvailability.verdict(.init(fieldAssistActive: fieldAssist,
                                                      medicalComplianceMode: hipaa, capability: capability))
    }

    func testTheTeamLearningsCapabilityIsTheGate() {
        XCTAssertEqual(verdict(.granted), .available)
        XCTAssertEqual(verdict(.notIncluded(held: [])), .notOffered)
        XCTAssertFalse(verdict(.denied(.noEvidence)).isAvailable)
        XCTAssertTrue(verdict(.denied(.noEvidence)).isOffered)
        XCTAssertTrue(verdict(.denied(.expired(Date()))).isOffered)
        XCTAssertNotNil(verdict(.denied(.unverifiableLicense)).refusal)
    }

    func testMedicalComplianceWithholdsItWhateverTheLicence() {
        XCTAssertEqual(verdict(hipaa: true, .granted), .notOffered)
        XCTAssertTrue(Config.hipaaDisabledTools.contains(ExperienceRecordingAvailability.withheldAlongside),
                      "withheld exactly where team_learning is")
    }

    func testFieldAssistOffIsNotOffered() {
        XCTAssertEqual(verdict(fieldAssist: false, .granted), .notOffered)
    }

    func testTheAppsOwnFactsFollowHipaaAndTheEntitlement() {
        let previousHipaa = Config.hipaaMode
        let previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        let previousEntitlement = EntitlementTestScope.grant(tier: .team)
        defer {
            Config.hipaaMode = previousHipaa
            if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
            EntitlementTestScope.restore(previousEntitlement)
        }
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        Config.hipaaMode = false
        XCTAssertEqual(ExperienceRecordingAvailability.current(), .available)
        Config.hipaaMode = true
        XCTAssertEqual(ExperienceRecordingAvailability.current(), .notOffered)
    }

    func testOnDeviceTranscriptionIsRequired() {
        XCTAssertNil(LiveExperienceCapture.refusal(speechAuthorized: true, microphoneAllowed: true,
                                                   recognizerExists: true, onDeviceSupported: true))
        XCTAssertNotNil(LiveExperienceCapture.refusal(speechAuthorized: true, microphoneAllowed: true,
                                                      recognizerExists: true, onDeviceSupported: false),
                        "no server fallback: a phone that can't transcribe on the device records nothing")
        XCTAssertNotNil(LiveExperienceCapture.refusal(speechAuthorized: false, microphoneAllowed: true,
                                                      recognizerExists: true, onDeviceSupported: true))
        XCTAssertNotNil(LiveExperienceCapture.refusal(speechAuthorized: true, microphoneAllowed: false,
                                                      recognizerExists: true, onDeviceSupported: true))
    }

    func testTheLiveCaptureNeverAsksForServerRecognition() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/FieldAssist/TeamLearning/ExperienceRecording/LiveExperienceCapture.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("request.requiresOnDeviceRecognition = true"))
        XCTAssertFalse(source.contains("requiresOnDeviceRecognition = false"))
    }
}

// MARK: - The car's row

final class ExperienceCarPlayRowTests: XCTestCase {

    private func job(_ reference: String, ended: Date? = nil) -> FieldSession {
        var session = FieldSession(id: "s-\(reference)", vaultId: "refrigeration", assetId: nil, mode: .aiOnly,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: ended,
                                   pausedAt: nil, resumedAt: nil, outcome: ended == nil ? .inProgress : .resolved,
                                   startLocation: nil, endLocation: nil, escalations: [], billableSeconds: 0)
        session.jobReference = reference
        return session
    }

    func testTheRowSitsAfterTheOpenJobAndBeforeFinishedOnes() throws {
        let rows = CarPlayJobsList.rows(active: job("1005"), history: [job("1004", ended: Date())],
                                        boundThreadId: nil, debriefAvailable: true, experience: .offered)
        XCTAssertEqual(rows.map(\.id).firstIndex(of: CarPlayJobsList.experienceRowId), 1)
        let row = try XCTUnwrap(rows.first { $0.id == CarPlayJobsList.experienceRowId })
        XCTAssertEqual(row.selection, .recordExperience)
        XCTAssertEqual(row.title, "Record experience")
        XCTAssertFalse(row.isActiveJob)
    }

    func testWhileRecordingTheSameRowStops() throws {
        let rows = CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: .recording)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, CarPlayJobsList.experienceRowId)
        XCTAssertEqual(row.selection, .stopExperienceRecording)
        XCTAssertEqual(row.title, "Stop recording")
    }

    func testHiddenMeansNoRow() {
        XCTAssertTrue(CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil).isEmpty)
        XCTAssertTrue(CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: .hidden).isEmpty)
    }

    func testTheRowFollowsTheVerdict() {
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .notOffered, recorderBusy: false), .hidden)
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .available, recorderBusy: false), .offered)
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .available, recorderBusy: true), .recording)
        XCTAssertEqual(CarPlayJobsList.experienceRow(verdict: .unavailable("lapsed"), recorderBusy: false), .offered)
    }

    func testTheRowIsOneGlance() {
        for experience in [CarPlayJobsList.ExperienceRow.offered, .recording] {
            let row = CarPlayJobsList.rows(active: nil, history: [], boundThreadId: nil, experience: experience)[0]
            XCTAssertLessThanOrEqual(row.title.count, 24)
            XCTAssertLessThanOrEqual(row.detail.count, 28)
        }
    }

    func testTheCarReadsEveryPromptAndHowToMoveOn() {
        let spoken = ExperienceRecorderCopy.carPlayPrompts.lowercased()
        for topic in ["equipment", "site", "problem", "checked and tried", "fixed it", "how sure", "next case", "that's all"] {
            XCTAssertTrue(spoken.contains(topic), topic)
        }
        XCTAssertEqual(ExperienceRecorderCopy.prompts.count, 5)
    }

    func testNoPlanLetterOrBetaInWhatItSays() {
        let lines = ExperienceRecorderCopy.prompts + [
            ExperienceRecorderCopy.standingLine, ExperienceRecorderCopy.carPlayPrompts, ExperienceRecorderCopy.cardHowTo,
            ExperienceRecorderCopy.cardTitle, ExperienceRecorderCopy.keptOnPhone, ExperienceRecorderCopy.capReached,
        ]
        for line in lines {
            XCTAssertNil(line.range(of: #"\bPlan [A-Z]{1,2}\b|\(beta\)|\bIM\b"#, options: .regularExpression), line)
        }
    }
}

// MARK: - The recorder

/// A capture that hears what the test says.
@MainActor
private final class ScriptedCapture: ExperienceCapture {
    var refusal: String?
    var lastStretch: String?
    var audioWritten = true
    private(set) var started = false
    private(set) var stopped = false
    private(set) var url: URL?
    var onStretch: (@MainActor (String) -> Void)?
    var locale = Locale(identifier: "en-US")
    var recognitionLocale: Locale { locale }

    func prepare() async -> String? { refusal }

    func start(writingTo url: URL, onStretch: @escaping @MainActor (String) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        started = true
        self.url = url
        self.onStretch = onStretch
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: 8192))
    }

    func stop() async -> ExperienceCaptureEnding {
        stopped = true
        return ExperienceCaptureEnding(audioWritten: audioWritten, lastStretch: lastStretch)
    }
}

@MainActor
final class ExperienceRecorderTests: XCTestCase {

    private var root: URL!
    private var store: ExperienceRecordingStore!
    private var spoken: [String] = []
    private var captures: [ScriptedCapture] = []
    private var verdict: ExperienceRecordingAvailability.Verdict = .available
    private var conversation = false
    private var openJob: String?
    private var filed: [String] = []
    private var fileOutcome: ExperienceJobFiling.Outcome = .filed(count: 1, jobReference: "1005")
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var tickers = 0

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExperienceRecorder-\(UUID().uuidString)", isDirectory: true)
        store = ExperienceRecordingStore(directory: root.appendingPathComponent("store", isDirectory: true))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeRecorder(configure: ((ScriptedCapture) -> Void)? = nil) -> ExperienceRecorder {
        ExperienceRecorder(store: store, seams: .init(
            availability: { [unowned self] in self.verdict },
            conversationActive: { [unowned self] in self.conversation },
            speak: { [unowned self] line in self.spoken.append(line) },
            makeCapture: { [unowned self] in
                let capture = ScriptedCapture()
                configure?(capture)
                self.captures.append(capture)
                return capture
            },
            captureFolder: { [unowned self] in self.root.appendingPathComponent("capture", isDirectory: true) },
            openJob: { [unowned self] in self.openJob },
            fileOnJob: { [unowned self] transcript in
                self.filed.append(transcript)
                return self.fileOutcome
            },
            vaultInForce: { "refrigeration" },
            now: { [unowned self] in self.clock },
            startTicker: { [unowned self] _ in
                self.tickers += 1
                return { [unowned self] in self.tickers -= 1 }
            }))
    }

    func testASessionSaysTheStandingLineOnceThenRecordsAndKeepsTheCase() async throws {
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        XCTAssertTrue(recorder.phase.isRecording)
        XCTAssertEqual(spoken.count, 1)
        XCTAssertTrue(spoken[0].contains(ExperienceRecorderCopy.standingLine))
        XCTAssertFalse(spoken[0].contains(ExperienceRecorderCopy.carPlayPrompts), "the phone shows the card instead")

        await recorder.heard("An Acme RX-200 throws E7 after rain.")
        clock = clock.addingTimeInterval(95)
        await recorder.heard("Dried the outdoor board and sealed the cover. That's all.")

        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(tickers, 0, "the clock stops with the recording")
        let kept = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(kept.transcript, "An Acme RX-200 throws E7 after rain. Dried the outdoor board and sealed the cover")
        XCTAssertEqual(kept.duration, 95)
        XCTAssertEqual(kept.vaultId, "refrigeration")
        XCTAssertEqual(kept.status, .recorded)
        XCTAssertTrue(store.hasAudio(kept.id), "the audio is kept on the phone")
        XCTAssertEqual(recorder.lastOutcome, .kept(recordingId: kept.id))
        XCTAssertEqual(spoken.last, ExperienceRecorderCopy.keptOnPhone)
    }

    func testInTheCarThePromptsAreReadAloud() async {
        let recorder = makeRecorder()
        await recorder.start(from: .carPlay)
        XCTAssertTrue(spoken[0].contains(ExperienceRecorderCopy.standingLine))
        XCTAssertTrue(spoken[0].contains(ExperienceRecorderCopy.carPlayPrompts(speaking: Locale(identifier: "en-US"))))
        XCTAssertEqual(recorder.surface, .carPlay)
    }

    /// A phone that transcribes in Spanish: the car reads the Spanish phrases, and the recorder
    /// hears them — and English's.
    func testTheRecorderHearsTheCapturesLanguageAndEnglish() async throws {
        let recorder = makeRecorder { $0.locale = Locale(identifier: "es-MX") }
        await recorder.start(from: .carPlay)
        XCTAssertTrue(spoken[0].contains("\u{201C}esa es una, siguiente caso\u{201D}"), spoken[0])
        XCTAssertTrue(spoken[0].contains("\u{201C}eso es todo\u{201D}"), spoken[0])

        await recorder.heard("La Acme RX-200 da E7. Esa es una, siguiente caso. La Brightline")
        guard case .recording(let number, _, _) = recorder.phase else { return XCTFail("the next case is recording") }
        XCTAssertEqual(number, 2)
        await recorder.heard("tenía el filtro sucio. That's one, next case.")
        guard case .recording(let third, _, _) = recorder.phase else { return XCTFail("English still starts the next") }
        XCTAssertEqual(third, 3)
        await recorder.heard("Eso es todo.")
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(store.newestFirst.map(\.transcript).sorted(),
                       ["La Acme RX-200 da E7", "La Brightline tenía el filtro sucio"])
    }

    func testNextCaseEndsOneRecordingAndStartsTheNextWithoutTheStandingLineAgain() async throws {
        let recorder = makeRecorder()
        await recorder.start(from: .carPlay)
        await recorder.heard("An Acme RX-200 throws E7 after rain, dried the board. That's one, next case. A Brightline short cycling")
        guard case .recording(let number, _, _) = recorder.phase else { return XCTFail("the next case is recording") }
        XCTAssertEqual(number, 2)
        XCTAssertEqual(captures.count, 2, "a fresh capture for each recording")
        XCTAssertTrue(captures[0].stopped)
        XCTAssertFalse(spoken.last!.contains(ExperienceRecorderCopy.standingLine))
        XCTAssertTrue(spoken.last!.hasSuffix(ExperienceRecorderCopy.nextCase))

        await recorder.heard("it was a dirty filter")
        await recorder.finish()
        XCTAssertEqual(Set(store.recordings.map(\.transcript)), [
            "An Acme RX-200 throws E7 after rain, dried the board",
            "A Brightline short cycling it was a dirty filter",
        ])
        XCTAssertEqual(spoken.filter { $0.contains(ExperienceRecorderCopy.standingLine) }.count, 1,
                       "the standing line is said once per session")

        // A new session says it again.
        await recorder.start(from: .phone)
        XCTAssertTrue(spoken.last!.contains(ExperienceRecorderCopy.standingLine))
    }

    func testTenMinutesEndsTheRecordingWhateverIsBeingSaid() async throws {
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        let started = clock
        await recorder.heard("The compressor on the walk-in")
        await recorder.tick(now: started.addingTimeInterval(ExperienceRecorderRules.recordingCap - 1))
        XCTAssertTrue(recorder.phase.isRecording)
        clock = started.addingTimeInterval(ExperienceRecorderRules.recordingCap + 4)
        await recorder.tick(now: clock)
        XCTAssertEqual(recorder.phase, .idle)
        let kept = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(kept.duration, Int(ExperienceRecorderRules.recordingCap), "never more than the cap")
        XCTAssertTrue(spoken.last!.hasPrefix(ExperienceRecorderCopy.capReached))
        XCTAssertTrue(ExperienceRecorderRules.capReached(startedAt: started, now: started.addingTimeInterval(600)))
        XCTAssertFalse(ExperienceRecorderRules.capReached(startedAt: started, now: started.addingTimeInterval(599)))
    }

    func testWordsStillBeingHeardAtStopBelongToTheCase() async throws {
        let recorder = makeRecorder { $0.lastStretch = "and a new fan motor fixed it. That's all." }
        await recorder.start(from: .phone)
        await recorder.heard("The condenser fan hums but won't turn")
        await recorder.finish()
        XCTAssertEqual(store.recordings.first?.transcript, "The condenser fan hums but won't turn and a new fan motor fixed it")
    }

    func testTheTranscriptIsRedactedBeforeItIsKept() async throws {
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        await recorder.heard("Ring the owner on sam.tane@example.com before you go up")
        await recorder.finish()
        let kept = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(kept.transcript.contains("sam.tane@example.com"))
        XCTAssertFalse(kept.redactions.isEmpty)
    }

    func testNothingHeardKeepsNothing() async {
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        await recorder.finish()
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertEqual(recorder.lastOutcome, .nothingHeard)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captures[0].url!.path), "its audio goes too")
    }

    // MARK: Gates

    func testWithheldOrUnavailableItNeverRecords() async {
        for refused in [ExperienceRecordingAvailability.Verdict.notOffered, .unavailable("Your access has lapsed.")] {
            verdict = refused
            spoken = []
            let recorder = makeRecorder()
            await recorder.start(from: .carPlay)
            XCTAssertEqual(recorder.phase, .idle)
            XCTAssertTrue(captures.isEmpty, "no microphone is opened")
            XCTAssertEqual(spoken, [refused.refusal!])
        }
    }

    func testAConversationListeningKeepsTheRecorderOff() async {
        conversation = true
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(recorder.lastOutcome, .refused(ExperienceRecorderCopy.conversationActive))
    }

    func testAPhoneThatCannotTranscribeOnTheDeviceRecordsNothing() async {
        let recorder = makeRecorder { $0.refusal = "no on-device recognition" }
        await recorder.start(from: .phone)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(recorder.lastOutcome, .refused("no on-device recognition"))
        XCTAssertFalse(captures[0].started)
    }

    // MARK: The open job

    func testARecordingDuringAnOpenJobFilesOnTheJobAndKeepsNoRecording() async throws {
        openJob = "session-1"
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        await recorder.heard("The 090's tubing sweats at the service valve")
        await recorder.finish()
        XCTAssertEqual(filed, ["The 090's tubing sweats at the service valve"])
        XCTAssertTrue(store.recordings.isEmpty, "a job's recording is a candidate, not a recollection")
        XCTAssertEqual(recorder.lastOutcome, .filedOnJob(count: 1, jobReference: "1005"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captures[0].url!.path), "its audio is not kept")
    }

    func testAJobThatClosesMidRecordingLeavesTheRecordingOnThePhone() async {
        openJob = "session-1"
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        await recorder.heard("The board needed reseating")
        openJob = nil
        await recorder.finish()
        XCTAssertTrue(filed.isEmpty)
        XCTAssertEqual(store.recordings.count, 1)
    }

    func testARefusedFilingIsKeptOnThePhoneInstead() async throws {
        openJob = "session-1"
        fileOutcome = .refused("Nothing was filed: no.")
        let recorder = makeRecorder()
        await recorder.start(from: .phone)
        await recorder.heard("The board needed reseating")
        await recorder.finish()
        let kept = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(recorder.lastOutcome, .keptAfterRefusal(recordingId: kept.id, reason: "Nothing was filed: no."))
    }
}

/// The open-job path through today's filing: a `spoken` candidate bound to the job.
@MainActor
final class ExperienceJobFilingTests: XCTestCase {

    private var root: URL!
    private var sessions: FieldSessionService!
    private var candidates: LearningCandidateStore!
    private var service: LearningCandidateService!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExperienceJobFiling-\(UUID().uuidString)", isDirectory: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()
        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        candidates = LearningCandidateStore(directory: root.appendingPathComponent("candidates", isDirectory: true))
        service = LearningCandidateService(store: candidates, sessions: sessions)
        service.authorName = { "Sam Tane" }
    }

    override func tearDown() {
        service = nil
        candidates = nil
        sessions = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    func testItFilesASpokenCandidateBoundToTheJob() throws {
        let session = try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "WO-4471")
        let outcome = ExperienceJobFiling.file("The 090's tubing sweats at the service valve", with: service)
        XCTAssertEqual(outcome, .filed(count: 1, jobReference: "WO-4471"))
        let candidate = try XCTUnwrap(candidates.candidates.first)
        XCTAssertEqual(candidate.origin, .spoken)
        XCTAssertEqual(candidate.sessionId, session.id)
        XCTAssertEqual(candidate.jobReference, "WO-4471")
        XCTAssertEqual(candidate.finding, "The 090's tubing sweats at the service valve")
    }

    func testALongRecordingIsFiledInPartsOnTheSameJob() throws {
        _ = try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "WO-4471")
        let text = String(repeating: "The fan seizes after a wet night, so check the bearing first. ", count: 70)
        guard case .filed(let count, _) = ExperienceJobFiling.file(text, with: service) else {
            return XCTFail("filed")
        }
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(candidates.candidates.count, count)
        XCTAssertEqual(Set(candidates.candidates.map(\.jobReference)), ["WO-4471"])
    }

    func testWithoutTheCapabilityNothingIsFiled() throws {
        _ = try sessions.startSession(vaultId: "refrigeration", assetId: nil, jobReference: "WO-4471")
        service.capability = { .notIncluded(held: []) }
        guard case .refused = ExperienceJobFiling.file("The fan seizes", with: service) else {
            return XCTFail("refused")
        }
        XCTAssertTrue(candidates.candidates.isEmpty)
    }
}
