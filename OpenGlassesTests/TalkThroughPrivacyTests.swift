import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b), "What is kept": nothing new. Where the technician was, how often they were
/// "off order" and which words were caught never leave the phone and are never recorded; a step
/// they confirm is recorded exactly as a spoken "next" is.
@MainActor
final class TalkThroughPrivacyTests: XCTestCase {

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    /// Code with comments and string literals removed, as `LiveHintsGuardTests` reads it.
    private static func code(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
        return text
    }

    private func talkThroughFiles() throws -> [URL] {
        var files = try FileManager.default.contentsOfDirectory(
            at: Self.sources.appendingPathComponent("Services/TalkThrough"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        files.append(Self.sources.appendingPathComponent("App/AppState+TalkThrough.swift"))
        files.append(Self.sources.appendingPathComponent("App/Views/Job/TalkThroughCard.swift"))
        return files
    }

    // MARK: - The source

    func testTalkThroughNamesNoStoreThatKeepsAnything() throws {
        let files = try talkThroughFiles()
        XCTAssertGreaterThanOrEqual(files.count, 6, "sanity: the talk-through sources were found")
        let forbidden = [
            // The job, its record and the office.
            "SessionLogger", "logger", "WorkRecord", "SessionExport", "OfficeOutbox", "OfficeTransport",
            "OfficeDelivery", "offlineQueue", "QueuedOp", "CaptureRecord", "mutateSession", "appendUserMessage",
            // An apprentice's logbook and the team's learnings.
            "Logbook", "LearningCandidate", "TeamLearning", "learningCandidates",
            // The conversation, memory and disk.
            "ConversationStore", "BrainStore", "SemanticMemoryStore", "UserMemory", "MemoryLoopService",
            "CaptionSessionStore", "SavedNotesStore", "UserDefaults", "FileManager", "write(to", "JSONStore",
            "Spotlight", "CSSearchableItem", "@AppStorage",
        ]
        for url in files {
            let code = try Self.code(url)
            for name in forbidden {
                XCTAssertFalse(code.contains(name), "\(url.lastPathComponent) names \(name): talk-through keeps nothing")
            }
        }
    }

    func testTheLogNeverSaysWhereTheyWereOrWhatWasCaught() throws {
        for url in try talkThroughFiles() {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let logLines = raw.components(separatedBy: "\n").filter { $0.contains("PrivacyLog.") || $0.contains("PrivacyToken(") }
            for line in logLines {
                for word in ["offOrder", "off order", "caution", "caught", "phrase", "proposal", "propose", "stepId",
                             "title", "text)", "question)", "line)"] {
                    XCTAssertFalse(line.contains(word), "\(url.lastPathComponent): a log line mentions \(word): \(line)")
                }
            }
        }
    }

    func testNoPrintOrNSLog() throws {
        for url in try talkThroughFiles() {
            let code = try Self.code(url)
            XCTAssertFalse(code.contains("print("), url.lastPathComponent)
            XCTAssertFalse(code.contains("NSLog("), url.lastPathComponent)
        }
    }

    // MARK: - Behaviour

    /// The kinds and payload keys of each event, without timestamps: what a run records.
    private func shape(_ events: [SessionLogger.Event]) -> [String] {
        events.map { event in
            "\(event.kind.rawValue)|\(event.text ?? "")|" + (event.payload ?? [:]).keys.sorted().map { key in
                "\(key)=\(String(describing: event.payload?[key]?.value ?? ""))"
            }.joined(separator: ",")
        }
    }

    func testNarrationOffOrderACaughtPhraseAndADeclineRecordNothing() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        let before = rig.logger.readEvents()
        rig.say("Leave it plugged in, nobody will notice.")      // a caught phrase
        rig.say("Lifting out the filter basket.")
        rig.say("Rinsing the filter mesh under the tap.")        // off order: the drain was skipped
        XCTAssertNotNil(rig.service.offOrderLine)
        rig.say("Opening the drain plug now.")
        rig.say("Letting the chamber empty into the bucket.")    // a proposal
        XCTAssertNotNil(rig.service.proposal)
        rig.say("no")                                            // declined
        XCTAssertNil(rig.service.proposal)
        XCTAssertEqual(rig.visited, ["isolate"], "narration alone never moves the runner")
        XCTAssertEqual(shape(rig.logger.readEvents()), shape(before), "nothing of it is in the job's record")
        rig.service.stop()
        XCTAssertNil(rig.service.offOrderLine)
        XCTAssertNil(rig.service.proposal)
    }

    func testAConfirmedStepIsRecordedExactlyAsASpokenNext() throws {
        // A spoken "next" through the no-model voice, on its own run.
        let spokenRoot = ProcedureAnswerFixtures.temporaryRoot("TalkThroughSpokenNext")
        defer { try? FileManager.default.removeItem(at: spokenRoot) }
        let spokenLogger = ProcedureAnswerFixtures.makeLogger(root: spokenRoot)
        let spokenHost = try ProcedureRunnerHost(TalkThroughFixtures.procedure(), logger: spokenLogger)
        let loop = ProcedureVoiceLoop(host: spokenHost, supportsOnDeviceRecognition: { true })
        let start = spokenLogger.readEvents().count
        _ = loop.handle("next", locale: Locale(identifier: "en_US"))
        let spokenNext = Array(spokenLogger.readEvents().dropFirst(start))

        // The same step, confirmed after talk-through proposed it.
        let rig = try TalkThroughRig()
        rig.service.start()
        let mark = rig.logger.readEvents().count
        rig.say("Opening the drain plug now.")
        rig.say("Letting the chamber empty into the bucket.")
        XCTAssertNil(rig.service.confirmProposal())
        let confirmed = Array(rig.logger.readEvents().dropFirst(mark))

        XCTAssertEqual(rig.visited, spokenHost.activeProcedureVisited)
        XCTAssertFalse(spokenNext.isEmpty)
        XCTAssertEqual(shape(confirmed), shape(spokenNext), "the record can't tell a confirmed proposal from a spoken next")
        for event in confirmed {
            XCTAssertFalse((event.text ?? "").localizedCaseInsensitiveContains("bucket"), "no narration in the record")
        }
        rig.service.stop()
    }

    func testAtStopNothingOfTheSessionRemains() throws {
        let rig = try TalkThroughRig()
        rig.captions.contextualStrings = ["before"]
        rig.service.start()
        XCTAssertTrue(rig.captions.contextualStrings.contains("Drain the chamber"))
        rig.say("How tight should the priming cap be?")
        rig.say("Opening the drain plug now.")
        rig.service.stop()
        XCTAssertEqual(rig.captions.contextualStrings, ["before"], "the recogniser's words go back as they were")
        XCTAssertNil(rig.service.questionCard)
        XCTAssertNil(rig.service.currentHint)
        XCTAssertNil(rig.service.procedureId)
        XCTAssertFalse(rig.service.justGo)
    }
}
