import XCTest
@testable import OpenGlasses

@MainActor
final class RecordedSessionStoreTests: XCTestCase {
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordedSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func makeSession(
        id: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        audioFileName: String = "recording.m4a",
        transcript: String = "",
        state: TranscriptionState = .pending
    ) -> RecordedSession {
        RecordedSession(
            id: id,
            title: "Recording — Test",
            startedAt: startedAt,
            duration: 12,
            audioFileName: audioFileName,
            transcript: transcript,
            state: state,
            failureReason: nil
        )
    }

    func testRoundTripAddUpdateAndDelete() throws {
        try withTemporaryDirectory { directory in
            let id = UUID()
            let store = RecordedSessionStore(documentsDirectory: directory)
            var session = makeSession(id: id)
            store.add(session)

            var reloaded = RecordedSessionStore(documentsDirectory: directory)
            XCTAssertEqual(reloaded.sessions, [session])

            session.duration = 42
            session.transcript = "Updated transcript"
            reloaded.update(session)

            reloaded = RecordedSessionStore(documentsDirectory: directory)
            XCTAssertEqual(reloaded.sessions.first?.duration, 42)
            XCTAssertEqual(reloaded.sessions.first?.transcript, "Updated transcript")

            reloaded.delete(session)
            XCTAssertTrue(RecordedSessionStore(documentsDirectory: directory).sessions.isEmpty)
        }
    }

    func testSessionsAreNewestFirst() throws {
        try withTemporaryDirectory { directory in
            let store = RecordedSessionStore(documentsDirectory: directory)
            let oldest = makeSession(startedAt: Date(timeIntervalSince1970: 100))
            let newest = makeSession(startedAt: Date(timeIntervalSince1970: 300))
            let middle = makeSession(startedAt: Date(timeIntervalSince1970: 200))

            store.add(oldest)
            store.add(newest)
            store.add(middle)

            XCTAssertEqual(store.sessions.map(\.startedAt), [
                newest.startedAt,
                middle.startedAt,
                oldest.startedAt,
            ])
        }
    }

    func testDeleteUnlinksAudioFile() throws {
        try withTemporaryDirectory { directory in
            let store = RecordedSessionStore(documentsDirectory: directory)
            let session = makeSession(audioFileName: "preserved.m4a")
            let audioURL = store.audioURL(for: session)
            try FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
            store.add(session)

            store.delete(session)

            XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
            XCTAssertTrue(store.sessions.isEmpty)
        }
    }

    func testCorruptJSONLoadsAsEmptyWithoutCrashing() throws {
        try withTemporaryDirectory { directory in
            let storageURL = directory.appendingPathComponent(RecordedSessionStore.storageFileName)
            try Data("not-json".utf8).write(to: storageURL)

            let store = RecordedSessionStore(documentsDirectory: directory)

            XCTAssertTrue(store.sessions.isEmpty)
        }
    }

    /// Only the bare filename is persisted: an iOS sandbox's absolute container path changes
    /// between launches, so the audio URL must be rebuilt from the current Documents directory.
    func testAudioURLUsesCurrentDocumentsDirectoryAndBareFileName() throws {
        try withTemporaryDirectory { firstDirectory in
            try withTemporaryDirectory { currentDirectory in
                let session = makeSession(
                    audioFileName: "/old/container/Documents/Recordings/moved.m4a"
                )
                let firstStore = RecordedSessionStore(documentsDirectory: firstDirectory)
                let currentStore = RecordedSessionStore(documentsDirectory: currentDirectory)
                firstStore.add(session)
                currentStore.add(session)

                XCTAssertEqual(firstStore.sessions.first?.audioFileName, "moved.m4a")
                XCTAssertEqual(currentStore.sessions.first?.audioFileName, "moved.m4a")
                XCTAssertEqual(
                    currentStore.audioURL(for: session),
                    currentDirectory
                        .appendingPathComponent(RecordedSessionStore.recordingsDirectoryName)
                        .appendingPathComponent("moved.m4a")
                )
                XCTAssertNotEqual(
                    firstStore.audioURL(for: session).deletingLastPathComponent(),
                    currentStore.audioURL(for: session).deletingLastPathComponent()
                )
            }
        }
    }

    func testStateTransitionsPendingToTranscribingToDone() throws {
        try withTemporaryDirectory { directory in
            let store = RecordedSessionStore(documentsDirectory: directory)
            var session = makeSession(state: .pending)
            store.add(session)
            XCTAssertEqual(store.sessions.first?.state, .pending)

            session.state = .transcribing
            store.update(session)
            XCTAssertEqual(store.sessions.first?.state, .transcribing)

            session.state = .done
            session.transcript = "Finished transcript"
            store.update(session)
            XCTAssertEqual(store.sessions.first?.state, .done)
            XCTAssertEqual(store.sessions.first?.transcript, "Finished transcript")
        }
    }

    func testEmptyPostHocTranscriptDoesNotClobberLiveCaptionText() {
        let session = makeSession(transcript: "Useful live-caption text")

        let completed = session.applyingTranscription("   \n", state: .done)

        XCTAssertEqual(completed.transcript, "Useful live-caption text")
        XCTAssertEqual(completed.state, .done)
    }

    // MARK: - RecordingTranscriber.join (pure)

    func testJoinLabelsSpeakersOnlyWhenMultiplePresent() {
        let multi: [SpeakerTurn] = [
            SpeakerTurn(speaker: 0, text: "Hello", start: 0, end: 1),
            SpeakerTurn(speaker: 1, text: "Hi there", start: 1, end: 2),
            SpeakerTurn(speaker: 0, text: "  ", start: 2, end: 3),
        ]
        XCTAssertEqual(
            RecordingTranscriber.join(turns: multi),
            "Speaker 1: Hello\nSpeaker 2: Hi there"
        )

        let single: [SpeakerTurn] = [
            SpeakerTurn(speaker: 0, text: "Just", start: 0, end: 1),
            SpeakerTurn(speaker: 0, text: "me", start: 1, end: 2),
        ]
        XCTAssertEqual(RecordingTranscriber.join(turns: single), "Just me")
    }
}
