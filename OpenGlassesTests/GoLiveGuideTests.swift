import XCTest
@testable import OpenGlasses

/// Plan KH. The guide must only say what the app and the platforms do, and Go Live must never
/// put an open microphone on air over a black picture because no glasses are connected.
final class GoLiveGuideTests: XCTestCase {

    // MARK: - The guide

    func testEveryPlatformHasItsOwnKeyLine() {
        let lines = GoLivePlatform.allCases.map(GoLiveGuide.keyLine(for:))
        XCTAssertTrue(lines.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(lines).count, GoLivePlatform.allCases.count)
    }

    func testEachKnownPlatformNamesItself() {
        XCTAssertTrue(GoLiveGuide.keyLine(for: .youtube).contains("YouTube Studio"))
        XCTAssertTrue(GoLiveGuide.keyLine(for: .twitch).contains("Twitch Creator Dashboard"))
        XCTAssertTrue(GoLiveGuide.keyLine(for: .kick).contains("Kick Creator Dashboard"))
        XCTAssertTrue(GoLiveGuide.keyLine(for: .tiktok).contains("TikTok"))
    }

    /// TikTok's own pages give no path, so its line names none.
    func testTikTokStatesNoPathItsPagesDoNotGive() {
        let line = GoLiveGuide.keyLine(for: .tiktok)
        XCTAssertTrue(line.contains("stream or creator dashboard"))
        for claim in ["LIVE Studio", "LIVE Center", "followers"] {
            XCTAssertFalse(line.contains(claim), claim)
        }
    }

    /// Twitch's page says "stream key"; "primary" is a dashboard label it does not state.
    func testKeyLinesKeepToThePlatformsWords() {
        XCTAssertFalse(GoLiveGuide.keyLine(for: .twitch).contains("primary"))
        XCTAssertTrue(GoLiveGuide.keyLine(for: .youtube).contains("Stream tab"))
        XCTAssertTrue(GoLiveGuide.keyLine(for: .kick).contains("Stream URL and Key"))
    }

    func testCustomRTMPMentionsTheURL() {
        XCTAssertTrue(GoLiveGuide.keyLine(for: .custom).contains("RTMP URL"))
    }

    func testTheStepsCarryOnlyTheSelectedPlatformsKeyLine() {
        for platform in GoLivePlatform.allCases {
            let steps = GoLiveGuide.steps(for: platform)
            XCTAssertTrue(steps.contains(GoLiveGuide.keyLine(for: platform)))
            for other in GoLivePlatform.allCases where other != platform {
                XCTAssertFalse(steps.contains(GoLiveGuide.keyLine(for: other)))
            }
        }
    }

    func testTheStepsSayHowToStop() {
        for platform in GoLivePlatform.allCases {
            XCTAssertTrue(GoLiveGuide.steps(for: platform).contains { $0.contains("again to stop") },
                          "\(platform) lost the stop instruction")
        }
    }

    func testTheStepsCoverTheKeyAndTheWayIn() {
        let steps = GoLiveGuide.steps(for: .youtube).joined(separator: " ")
        XCTAssertTrue(steps.contains("Treat it like a password"))
        XCTAssertTrue(steps.contains("Avenkin tab"), "the home tab's rendered title")
        XCTAssertTrue(steps.contains("Preview"), "the tile's rendered label")
        XCTAssertTrue(steps.contains("Go Live button"), "the button's accessibility label")
        XCTAssertTrue(steps.contains("LIVE"))
        XCTAssertTrue(steps.contains("switch camera"))
        XCTAssertTrue(steps.contains("a few seconds"))
    }

    func testTheNotesSayWhatTheBlurDoesNotCover() {
        let notes = GoLiveGuide.phoneCameraNotes.joined(separator: " ")
        XCTAssertTrue(notes.contains("glasses camera only"))
        XCTAssertTrue(notes.contains("microphone"))
    }

    func testTheReadyLineNamesNoCamera() {
        for platform in GoLivePlatform.allCases {
            let line = GoLiveGuide.readyLine(for: platform)
            XCTAssertFalse(line.lowercased().contains("glasses"), line)
            XCTAssertFalse(line.lowercased().contains("phone"), line)
        }
        XCTAssertTrue(GoLiveGuide.readyLine(for: .youtube).contains("YouTube"))
        XCTAssertTrue(GoLiveGuide.readyLine(for: .tiktok).contains("TikTok"))
    }

    func testNoPlanLettersReachTheScreen() throws {
        let pattern = try NSRegularExpression(pattern: #"\b(?:Plan [A-Z]{1,2}|[A-Z]{2}\d?\s?P\d)\b"#)
        var lines = GoLiveGuide.phoneCameraNotes
        for platform in GoLivePlatform.allCases {
            lines += GoLiveGuide.steps(for: platform)
            lines.append(GoLiveGuide.readyLine(for: platform))
        }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertNil(pattern.firstMatch(in: line, range: range), line)
        }
    }

    func testAnUnknownStoredPlatformIsACustomEndpoint() {
        XCTAssertEqual(GoLivePlatform(stored: "youtube"), .youtube)
        XCTAssertEqual(GoLivePlatform(stored: "tiktok"), .tiktok)
        XCTAssertEqual(GoLivePlatform(stored: "something-new"), .custom)
    }

    /// The Picker's tags in `ServicesSettingsView` are these raw values.
    func testThePlatformsAreTheOnesSettingsStores() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "OpenGlasses/Sources/App/Views/ServicesSettingsView.swift"), encoding: .utf8)
        for platform in GoLivePlatform.allCases {
            XCTAssertTrue(source.contains(".tag(\"\(platform.rawValue)\")"), platform.rawValue)
        }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Tapping Go Live

    /// Set up, glasses connected, nothing blocking: the plain case each rule moves one thing from.
    private func facts(_ change: (inout BroadcastGoLive.Facts) -> Void = { _ in }) -> BroadcastGoLive.Facts {
        var facts = BroadcastGoLive.Facts(
            isBroadcasting: false, isConfigured: true, preferredSource: .glasses,
            glassesConnected: true, faceBlurOn: false, phoneCameraDenied: false, setupReachable: true)
        change(&facts)
        return facts
    }

    func testWithGlassesItStartsOnTheCameraSetting() {
        XCTAssertEqual(BroadcastGoLive.decide(facts()), .toggle(startSource: nil))
        XCTAssertEqual(BroadcastGoLive.decide(facts { $0.preferredSource = .phoneFront }),
                       .toggle(startSource: nil))
    }

    func testWithNoGlassesItFallsBackToThePhone() {
        XCTAssertEqual(BroadcastGoLive.decide(facts { $0.glassesConnected = false }),
                       .toggle(startSource: .phoneBack))
    }

    func testAPhoneSettingNeedsNoFallback() {
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.glassesConnected = false
            $0.preferredSource = .phoneFront
        }), .toggle(startSource: nil))
    }

    func testTheFallbackNeverDropsTheBlurSilently() {
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.glassesConnected = false
            $0.faceBlurOn = true
        }), .phoneCameraNotBlurred)
    }

    func testTheBlurDoesNotStopAGlassesStream() {
        XCTAssertEqual(BroadcastGoLive.decide(facts { $0.faceBlurOn = true }), .toggle(startSource: nil))
    }

    func testARefusedPhoneCameraIsSaidRatherThanStreamedBlack() {
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.glassesConnected = false
            $0.phoneCameraDenied = true
        }), .phoneCameraDenied)
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.preferredSource = .phoneBack
            $0.phoneCameraDenied = true
        }), .phoneCameraDenied)
    }

    func testARefusedPhoneCameraDoesNotStopAGlassesStream() {
        XCTAssertEqual(BroadcastGoLive.decide(facts { $0.phoneCameraDenied = true }),
                       .toggle(startSource: nil))
    }

    func testNotSetUpOffersSetupOnlyWhereItCanBeReached() {
        XCTAssertEqual(BroadcastGoLive.decide(facts { $0.isConfigured = false }),
                       .needsSetup(canOpenSettings: true))
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.isConfigured = false
            $0.setupReachable = false
        }), .needsSetup(canOpenSettings: false))
    }

    func testNotSetUpComesBeforeAnythingAboutTheCamera() {
        XCTAssertEqual(BroadcastGoLive.decide(facts {
            $0.isConfigured = false
            $0.glassesConnected = false
            $0.faceBlurOn = true
        }), .needsSetup(canOpenSettings: true))
    }

    func testStoppingAlwaysWins() {
        XCTAssertEqual(BroadcastGoLive.decide(.init(
            isBroadcasting: true, isConfigured: false, preferredSource: .glasses,
            glassesConnected: false, faceBlurOn: true, phoneCameraDenied: true, setupReachable: false)),
                       .toggle(startSource: nil))
    }

    // MARK: - The way in

    func testThePreviewIsReachableWithGlassesOrWithStreamingSetUp() {
        XCTAssertTrue(HomeGridTilePresence.livePreviewReachable(glassesConnected: true, broadcastConfigured: false))
        XCTAssertTrue(HomeGridTilePresence.livePreviewReachable(glassesConnected: false, broadcastConfigured: true))
        XCTAssertFalse(HomeGridTilePresence.livePreviewReachable(glassesConnected: false, broadcastConfigured: false))
    }

    // MARK: - Things to Try

    func testTheLinkNeedsStreamingSetUp() {
        XCTAssertTrue(StreamLiveLink.isVisible(broadcastConfigured: true, in: ScenarioContext()))
        XCTAssertFalse(StreamLiveLink.isVisible(broadcastConfigured: false, in: ScenarioContext()))
    }

    func testTheLinkLeavesWithItsSettings() {
        var context = ScenarioContext()
        context.unreachableSettings = [.capture]
        XCTAssertFalse(StreamLiveLink.isVisible(broadcastConfigured: true, in: context))
        context.unreachableSettings = [.tools]
        XCTAssertTrue(StreamLiveLink.isVisible(broadcastConfigured: true, in: context))
    }

    func testSimpleModeHidesTheLinkThroughItsCategory() {
        let shown = Set(SettingsCatalog.visible(simpleMode: true).map(\.id))
        var context = ScenarioContext()
        context.unreachableSettings = Set(SettingsCategoryID.allCases).subtracting(shown)
        XCTAssertFalse(StreamLiveLink.isVisible(broadcastConfigured: true, in: context))
    }

    func testHIPAAHidesTheLink() {
        var context = ScenarioContext()
        context.hipaaMode = true
        XCTAssertFalse(StreamLiveLink.isVisible(broadcastConfigured: true, in: context))
    }

    func testTheLinkIsNotAScenario() {
        XCTAssertFalse(ScenarioCatalog.all.contains { $0.title.localizedCaseInsensitiveContains("stream live") })
    }
}
