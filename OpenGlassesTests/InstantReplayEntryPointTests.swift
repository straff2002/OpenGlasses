import XCTest
@testable import OpenGlasses

/// Instant Replay P0–P2 — the roster entry and the relay subscription, the store registration, and
/// the three ways in: the tool, the temple tap and the Shortcut.
final class InstantReplayEntryPointTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Code lines only: the documentation names the APIs it promises never to use.
    private func code(_ relative: String) throws -> String {
        try source(relative).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
            .joined(separator: "\n")
    }

    // MARK: - Through the privacy relay, on the roster

    func testTheBufferIsOnTheRosterAsARelayFedRecording() {
        let entry = OutboundFrameConsumer.instantReplayBuffer
        XCTAssertEqual(entry.owningType, "ReplayBufferService")
        XCTAssertEqual(entry.scope, .recording)
        XCTAssertEqual(entry.tap, .outboundRelay)
        XCTAssertEqual(entry.mechanism, .relay)
        XCTAssertFalse(OutboundFrameConsumer.typesAllowedOnTheRawCameraTap.contains("ReplayBufferService"))
        XCTAssertFalse(OutboundFrameConsumer.typesAllowedOnARawStill.contains("ReplayBufferService"))
    }

    func testTheBufferIsFedOnlyFromTheRelayAndNeverStartsTheCamera() throws {
        let service = try code("OpenGlasses/Sources/Services/InstantReplay/ReplayBufferService.swift")
        for forbidden in ["framePublisher", "latestFrame", "onVideoFrame", "startStreaming",
                          "claimStream", "audioFramePublisher", "audioCodec"] {
            XCTAssertFalse(service.contains(forbidden), "the buffer must not touch \(forbidden)")
        }
        let wiring = try code("OpenGlasses/Sources/App/AppState+InstantReplay.swift")
        XCTAssertTrue(wiring.contains("instantReplay.connect(seams, source: outboundFrames.publisher)"))
        for forbidden in ["framePublisher", "latestFrame", "startStreaming", "claimStream"] {
            XCTAssertFalse(wiring.contains(forbidden), "the wiring must not touch \(forbidden)")
        }
    }

    func testTheReplayModuleHasNoNetworkRoute() throws {
        for file in ["ReplayBufferService", "ReplaySegmentWriter", "ReplaySegmentRing",
                     "ReplaySaveRequest", "ReplayBufferPolicy"] {
            let text = try code("OpenGlasses/Sources/Services/InstantReplay/\(file).swift")
            for network in ["URLSession", "URLRequest", "NWConnection", "WebSocket"] {
                XCTAssertFalse(text.contains(network), "\(file) reaches the network through \(network)")
            }
        }
    }

    // MARK: - The store

    func testTheStoreIsRegisteredProtectedAndOutOfBackup() {
        let record = SensitiveStore.instantReplayBuffer.record
        XCTAssertEqual(record.dataClass, .media)
        XCTAssertEqual(record.subjectLinkage, .thirdPartySubject)
        XCTAssertEqual(record.protection, .completeUnlessOpen)
        XCTAssertTrue(record.backupExcluded)
        XCTAssertEqual(record.owner, "ReplayBufferService")
        XCTAssertTrue(record.deleteAll.isAvailable)
        XCTAssertTrue(record.deleteSubject.isAvailable)
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.instantReplayBuffer))
    }

    // MARK: - The tool

    @MainActor
    func testTheToolSavesWhatWasAskedAndReportsStatus() async throws {
        var asked: [ReplaySaveRequest] = []
        let tool = InstantReplayTool(seams: .init(
            save: { request in
                asked.append(request)
                return ReplaySaveOutcome(result: .saved(destination: request.destination,
                                                        askedSeconds: request.seconds,
                                                        keptSeconds: request.seconds,
                                                        cappedForJob: false, photosLanded: nil))
            },
            status: { "Instant Replay is keeping the last 40 seconds, up to a minute." }))
        let saved = try await tool.execute(args: [:])
        XCTAssertEqual(saved, "Saved the last 30 seconds to Recordings.")
        let minute = try await tool.execute(args: ["action": "save", "seconds": 60, "destination": "job",
                                                   "caption": "relay chatter"])
        XCTAssertEqual(minute, "Saved the last minute to the job.")
        XCTAssertEqual(asked.last, ReplaySaveRequest(seconds: 60, destination: .job, caption: "relay chatter"))
        let status = try await tool.execute(args: ["action": "status"])
        XCTAssertEqual(status, "Instant Replay is keeping the last 40 seconds, up to a minute.")
        XCTAssertEqual(asked.count, 2)
    }

    @MainActor
    func testTheToolNamesReplayAndKeepTheLastButNeverSaveThat() {
        let tool = InstantReplayTool(seams: .init(save: { _ in .init(result: .refused(.couldNotSave)) },
                                                  status: { "" }))
        XCTAssertEqual(tool.name, "instant_replay")
        let description = tool.description.lowercased()
        XCTAssertTrue(description.contains("replay"))
        XCTAssertTrue(description.contains("keep the last"))
        XCTAssertTrue(description.contains("save the last"))
        // "save that" and "save it" belong to the job debrief's review.
        for phrase in ["\"save that\"", "\"save it\"", "\"keep it\""] {
            XCTAssertFalse(description.contains(phrase), "the tool must not claim \(phrase)")
        }
        XCTAssertTrue(DebriefReviewState.savePhrases.contains("save that"))
        XCTAssertEqual(tool.executionSemantics.effect, ToolExecutionSemantics.local().effect)
        XCTAssertEqual(PhoneCapturePolicy.route(forTool: "instant_replay"), .glassesOnly)
        XCTAssertTrue(ActivityTitler.hasTemplate(for: "instant_replay"))
    }

    // MARK: - The temple tap

    func testTheTempleTapSavesOnlyWhileTheBufferRuns() {
        let running = TempleContext(activity: .standby, replayRunning: true)
        XCTAssertEqual(TempleActionResolver.resolve(action: .saveReplay, context: running), .run(.saveReplay))
        let speaking = TempleContext(activity: .speaking, replayRunning: true)
        XCTAssertEqual(TempleActionResolver.resolve(action: .saveReplay, context: speaking), .run(.saveReplay),
                       "keeping a moment doesn't fight the reply for the audio")
        let stopped = TempleContext(activity: .standby, replayRunning: false)
        XCTAssertEqual(TempleActionResolver.resolve(action: .saveReplay, context: stopped),
                       .ignored(.replayNotRunning))
        XCTAssertEqual(TempleIgnoreReason.replayNotRunning.spokenLine, "Instant Replay isn't running.")
        let busy = TempleContext(activity: .busy, replayRunning: true)
        XCTAssertEqual(TempleActionResolver.resolve(action: .saveReplay, context: busy), .ignored(.busy))
    }

    func testTheTempleTapIsAssignableAndAcknowledgedWithTheKeptPair() {
        XCTAssertTrue(TempleAction.builtIns.contains(.saveReplay))
        XCTAssertEqual(TempleAction.builtIns.last, .nothing)
        XCTAssertEqual(TempleAction(rawValue: "saveReplay"), .saveReplay)
        XCTAssertEqual(TempleAction.saveReplay.rawValue, "saveReplay")
        XCTAssertEqual(TempleEarcon.for(.run(.saveReplay)), .recordingStopped)
    }

    // MARK: - The Shortcut

    func testTheShortcutOpensTheAppAndKeepsItsMetadataPlain() throws {
        #if !AVENKIN_PHONE_ONLY
        XCTAssertTrue(SaveGlassesReplayIntent.openAppWhenRun)
        #endif
        let intents = try source("OpenGlasses/Sources/App/Intents/CaptureIntents.swift")
        XCTAssertTrue(intents.contains("struct SaveGlassesReplayIntent: AppIntent"))
        XCTAssertTrue(intents.contains("\"Save Glasses Replay\""))
        XCTAssertTrue(intents.contains("saveInstantReplay(ReplaySaveRequest())"))
        // Not an App Shortcut: the provider is at the 10-shortcut cap.
        let provider = try source("OpenGlasses/Sources/App/Intents/AskOpenGlassesIntent.swift")
        XCTAssertFalse(provider.contains("SaveGlassesReplayIntent"))
    }

    // MARK: - The setting

    func testTheSettingIsOffByDefaultAndAnOrganisationCanOnlyPinItOff() {
        let saved = UserDefaults.standard.object(forKey: "instantReplayEnabled")
        defer { UserDefaults.standard.set(saved, forKey: "instantReplayEnabled") }
        UserDefaults.standard.removeObject(forKey: "instantReplayEnabled")
        XCTAssertFalse(Config.instantReplayEnabled)
        XCTAssertEqual(SettingKey.instantReplayEnabled.kind, .ceiling(pinnedTo: false))
        XCTAssertEqual(SettingKey.instantReplayEnabled.ceilingDescription, "Instant Replay is off")
    }

    func testTheBufferLengthDefaultsToAMinuteAndAcceptsOnlyItsChoices() {
        let saved = UserDefaults.standard.object(forKey: "instantReplayBufferSeconds")
        defer { UserDefaults.standard.set(saved, forKey: "instantReplayBufferSeconds") }
        UserDefaults.standard.removeObject(forKey: "instantReplayBufferSeconds")
        XCTAssertEqual(Config.instantReplayBufferSeconds, 60)
        Config.instantReplayBufferSeconds = 120
        XCTAssertEqual(Config.instantReplayBufferSeconds, 120)
        Config.instantReplayBufferSeconds = 45
        XCTAssertEqual(Config.instantReplayBufferSeconds, 120, "an unoffered length is refused")
    }

    func testAKeptReplayIsNamedAndListedAsOne() {
        let name = RecordingFiler.fileName(for: Date(timeIntervalSince1970: 0), fileExtension: "mp4",
                                           timeZone: TimeZone(identifier: "UTC")!,
                                           prefix: RecordingFiler.replayPrefix)
        XCTAssertEqual(name, "Replay_1970-01-01_000000.mp4")
        XCTAssertEqual(RecordingFiler.fileName(for: Date(timeIntervalSince1970: 0), fileExtension: "mp4",
                                               timeZone: TimeZone(identifier: "UTC")!),
                       "Recording_1970-01-01_000000.mp4", "ordinary recordings are named as before")
        let video = RecordedVideo(url: URL(fileURLWithPath: "/tmp/\(name)"), date: Date(), bytes: 1)
        XCTAssertTrue(video.isReplay)
    }
}
