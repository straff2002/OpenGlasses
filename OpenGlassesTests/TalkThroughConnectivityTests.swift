import XCTest
@testable import OpenGlasses

/// Plan JI §7a (P6b): with signal and without, the same narration gives the same positions and the
/// same hints; recognition stays on the phone where the rules say so; and nothing searches the web.
@MainActor
final class TalkThroughConnectivityTests: XCTestCase {

    private let narration = [
        "Isolator off, lead unplugged.",
        "Leave it plugged in, it's fine.",
        "Opening the drain plug now.",
        "Letting the chamber empty into the bucket.",
        "yes",
        "Chamber's empty.",
        "Lifting out the filter basket.",
        "Rinsing the filter mesh under the tap.",
        "yes",
    ]

    /// What one run shows: each proposal, each step's hint, each line said, the path walked.
    private struct Trace: Equatable {
        var proposals: [String] = []
        var hints: [[String]] = []
        var spoken: [String] = []
        var visited: [String] = []
    }

    /// Runs the narration. `online` decides whether a model can be asked; `dropAfter` takes the
    /// network away mid-step, after that many sentences.
    private func run(online: Bool, dropAfter: Int? = nil) throws -> Trace {
        let rig = try TalkThroughRig()
        rig.model.isAvailable = online
        rig.service.start()
        var trace = Trace()
        for (index, sentence) in narration.enumerated() {
            if let dropAfter, index == dropAfter { rig.model.isAvailable = false }
            rig.say(sentence)
            if let proposal = rig.service.proposal, trace.proposals.last != proposal.stepId {
                trace.proposals.append(proposal.stepId)
            }
            if let hint = rig.service.currentHint, trace.hints.last != hint.phoneLines {
                trace.hints.append(hint.phoneLines)
            }
        }
        trace.spoken = rig.ear.spoken
        trace.visited = rig.visited
        rig.service.stop()
        return trace
    }

    func testTheSameNarrationGivesTheSamePositionsAndHintsOnlineAndOffline() throws {
        let online = try run(online: true)
        let offline = try run(online: false)
        let dropped = try run(online: true, dropAfter: 3)
        XCTAssertEqual(online, offline)
        XCTAssertEqual(online, dropped, "the network dropping mid-step changes nothing about where they are")
        XCTAssertEqual(online.proposals, ["drain", "filter"])
        XCTAssertEqual(online.visited, ["isolate", "drain", "filter"])
        XCTAssertTrue(online.spoken.contains("Unplug the lead before opening the housing."),
                      "the caught phrase was said in both")
    }

    func testPositionAndHintsNeverAskAModel() throws {
        let rig = try TalkThroughRig()
        rig.service.start()
        for sentence in narration { rig.say(sentence) }
        XCTAssertEqual(rig.model.calls.count, 0)
        rig.service.stop()
    }

    // MARK: - Recognition on the phone

    func testThePhoneIsForcedByEachRule() {
        let none = TalkThroughRecognitionPolicy.requiresOnDevice(vaultOnly: false, medicalCompliance: false,
                                                                 medicalLocalOnly: false, privateConversation: false)
        XCTAssertFalse(none, "with signal and no rule, the server may recognise the trade words better")
        XCTAssertTrue(TalkThroughRecognitionPolicy.requiresOnDevice(vaultOnly: true, medicalCompliance: false,
                                                                    medicalLocalOnly: false, privateConversation: false))
        XCTAssertTrue(TalkThroughRecognitionPolicy.requiresOnDevice(vaultOnly: false, medicalCompliance: true,
                                                                    medicalLocalOnly: false, privateConversation: false))
        XCTAssertTrue(TalkThroughRecognitionPolicy.requiresOnDevice(vaultOnly: false, medicalCompliance: false,
                                                                    medicalLocalOnly: true, privateConversation: false))
        XCTAssertTrue(TalkThroughRecognitionPolicy.requiresOnDevice(vaultOnly: false, medicalCompliance: false,
                                                                    medicalLocalOnly: false, privateConversation: true))
    }

    func testTheSessionAppliesTheRuleToTheCaptionsAndLiftsItAtStop() throws {
        let rig = try TalkThroughRig()
        rig.service.recognitionMustStayOnPhone = { true }
        rig.service.start()
        XCTAssertEqual(rig.onDeviceRequests, [true])
        rig.service.stop()
        XCTAssertEqual(rig.onDeviceRequests, [true, false])

        let open = try TalkThroughRig()
        open.service.recognitionMustStayOnPhone = { false }
        open.service.start()
        open.service.stop()
        XCTAssertEqual(open.onDeviceRequests, [false, false])
    }

    func testTheCaptionServiceKeepsAForcedSessionOffTheServerPaths() throws {
        let source = try String(contentsOf: Self.sources.appendingPathComponent("Services/AmbientCaptionService.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("Config.translationCaptionsEnabled, !sessionRequiresOnDeviceRecognition"))
        XCTAssertTrue(source.contains("Config.isDiarizationConfigured, !sessionRequiresOnDeviceRecognition"))
        XCTAssertTrue(source.contains("request.requiresOnDeviceRecognition = true"))
    }

    // MARK: - No web search, either way

    private static var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources")
    }

    func testTalkThroughNamesNoWebSearch() throws {
        var files = try FileManager.default.contentsOfDirectory(
            at: Self.sources.appendingPathComponent("Services/TalkThrough"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 4, "sanity: the talk-through sources were found")
        files.append(Self.sources.appendingPathComponent("App/AppState+TalkThrough.swift"))
        for url in files {
            let code = try String(contentsOf: url, encoding: .utf8)
            for name in ["WebSearch", "web_search", "Perplexity", "DuckDuckGo", "searchWeb", "providerWebSearch",
                         "URLSession", "NativeToolRouter"] {
                XCTAssertFalse(code.contains(name), "\(url.lastPathComponent) names \(name): talk-through never searches the web")
            }
        }
    }

    func testAQuestionSearchesOnlyTheJobsManualsOnlineAndOffline() async throws {
        for online in [true, false] {
            let rig = try TalkThroughRig()
            rig.model.isAvailable = online
            rig.service.resolvedProvider = { .anthropic }
            rig.service.start()
            rig.say("How tight should the priming cap be?")
            await rig.service.waitUntilIdle()
            XCTAssertEqual(rig.manuals.queries, ["How tight should the priming cap be?"])
            XCTAssertEqual(rig.service.questionCard?.passage?.citation, "QMX90 Pump Guide, page 12")
            XCTAssertEqual(rig.service.questionCard?.source, online ? .model : .passage,
                           "offline the manual's passage stands; online the model's answer replaces it within the window")
            XCTAssertEqual(rig.model.calls.count, online ? 1 : 0)
            rig.service.stop()
        }
    }
}
