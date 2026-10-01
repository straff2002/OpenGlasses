import XCTest
@testable import OpenGlasses

/// Plan GS P0 regression — `music_control` keeps its name and actions, still tells the temple-tap
/// trigger to stand down before acting on the wearer's player, and routes through the providers.
@MainActor
final class MusicControlToolTests: XCTestCase {

    private var apple: RecordingMusicProvider!
    private var speaker: RecordingMusicProvider!
    private var homeAssistant: FakeHomeAssistant!
    private var standDowns = 0
    private var applePlaying = false
    private var defaultProvider: MusicProviderID = .appleMusic

    override func setUp() async throws {
        apple = RecordingMusicProvider(id: .appleMusic)
        speaker = RecordingMusicProvider(id: .homeAssistant)
        homeAssistant = FakeHomeAssistant()
        homeAssistant.players = [MusicFixtures.player("media_player.kitchen", name: "Kitchen")]
        standDowns = 0
        applePlaying = false
        defaultProvider = .appleMusic
    }

    private func tool(homeAssistantUsable: Bool = true) -> MusicControlTool {
        var tool = MusicControlTool()
        tool.makeEnvironment = { [unowned self] in
            MusicControlEnvironment(
                appleMusic: self.apple,
                homeAssistant: homeAssistantUsable ? self.speaker : nil,
                homeAssistantClient: homeAssistantUsable ? self.homeAssistant : nil,
                homeAssistantUnavailableLine: homeAssistantUsable ? nil : MusicPhraser.speakersNeedHomeAssistant,
                defaultProvider: self.defaultProvider,
                defaultSpeakerEntityId: nil,
                hiddenSpeakers: [],
                askWhenUnsure: true,
                appleMusicPlaying: { [unowned self] in self.applePlaying },
                postUserPlaybackRequested: { [unowned self] in self.standDowns += 1 })
        }
        return tool
    }

    func testNameAndLegacyActionsAreUnchanged() async throws {
        let music = tool(homeAssistantUsable: false)
        XCTAssertEqual(music.name, "music_control")
        for action in ["play", "pause", "toggle", "next", "previous", "now_playing", "shuffle"] {
            _ = try await music.execute(args: ["action": action])
        }
        _ = try await music.execute(args: ["action": "search", "query": "rumours"])
        _ = try await music.execute(args: ["action": "play_song", "query": "Dreams"])
        _ = try await music.execute(args: ["action": "play_artist", "query": "Fleetwood Mac"])
        XCTAssertEqual(apple.received.count, 10)
        XCTAssertEqual(apple.received.last?.0, .playByName(MusicRequestParser.request(from: "Fleetwood Mac", kind: .artist)))
    }

    func testCommandsStandDownTheTempleTriggerButReadsDoNot() async throws {
        let music = tool(homeAssistantUsable: false)
        _ = try await music.execute(args: ["action": "pause"])
        _ = try await music.execute(args: ["action": "play_song", "query": "Dreams"])
        XCTAssertEqual(standDowns, 2)
        _ = try await music.execute(args: ["action": "now_playing"])
        _ = try await music.execute(args: ["action": "search", "query": "Dreams"])
        XCTAssertEqual(standDowns, 2, "reads never touch the Now Playing claim")
    }

    func testTheLiveStandDownStillPostsTheTriggerNotification() {
        let posted = expectation(forNotification: MediaTriggerService.userPlaybackRequested, object: nil)
        MusicControlEnvironment.live().postUserPlaybackRequested()
        wait(for: [posted], timeout: 1)
    }

    func testSpeakerCommandsLeaveThePhonesNowPlayingAlone() async throws {
        let result = try await tool().execute(args: ["action": "pause", "device": "kitchen"])
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(speaker.received.first?.1?.entityId, "media_player.kitchen")
        XCTAssertEqual(standDowns, 0)
    }

    func testTargetInsideTheQueryRoutesToTheSpeaker() async throws {
        _ = try await tool().execute(args: ["action": "play", "query": "Rumours on the kitchen speaker"])
        XCTAssertEqual(speaker.received.first?.0, .playByName(MusicRequestParser.request(from: "rumours")))
    }

    func testSpotifyGetsTheGenericRefusal() async throws {
        let result = try await tool(homeAssistantUsable: false).execute(args: ["action": "play", "query": "Discover Weekly on Spotify"])
        XCTAssertEqual(result, MusicPhraser.cannotControl("Spotify"))
        XCTAssertTrue(apple.received.isEmpty)
        let byProvider = try await tool(homeAssistantUsable: false).execute(args: ["action": "next", "provider": "spotify"])
        XCTAssertEqual(byProvider, MusicPhraser.cannotControl("Spotify"))
    }

    func testLikeExplainsItAddedToTheLibrary() async throws {
        apple.reply = .done("Added Dreams by Fleetwood Mac to your library.")
        let result = try await tool(homeAssistantUsable: false).execute(args: ["action": "like"])
        XCTAssertEqual(result, MusicPhraser.likeIsAddToLibrary)
        XCTAssertEqual(apple.received.first?.0, .addToLibrary(nil))
    }

    func testDevicesListsSpeakersWithoutAProviderCall() async throws {
        let result = try await tool().execute(args: ["action": "devices"])
        XCTAssertEqual(result, "You have one speaker available: Kitchen.")
        let none = try await tool(homeAssistantUsable: false).execute(args: ["action": "devices"])
        XCTAssertEqual(none, MusicPhraser.speakersNeedHomeAssistant)
    }

    func testPhoneDefaultSkipsTheSpeakerFetchWhileThePhoneIsPlaying() async throws {
        applePlaying = true
        _ = try await tool().execute(args: ["action": "pause"])
        XCTAssertEqual(homeAssistant.stateFetches, 0)
        XCTAssertEqual(apple.received.first?.0, .pause)
    }

    func testMissingQueryAndUnknownActionAnswerWithoutActing() async throws {
        let music = tool(homeAssistantUsable: false)
        let missing = try await music.execute(args: ["action": "play_song"])
        XCTAssertEqual(missing, "What song should I play?")
        let unknown = try await music.execute(args: ["action": "dance"])
        XCTAssertTrue(unknown.hasPrefix("Unknown action 'dance'"), unknown)
        XCTAssertTrue(apple.received.isEmpty)
    }

    func testVolumeLevelAcceptsPercentOrFraction() {
        XCTAssertEqual(MusicToolRequest.level(40), 0.4)
        XCTAssertEqual(MusicToolRequest.level("75%"), 0.75)
        XCTAssertEqual(MusicToolRequest.level(0.2), 0.2)
        XCTAssertNil(MusicToolRequest.level(-5))
    }

    // MARK: - Temple tap (the music action in the tap set)

    func testMusicTapRunsOnlyBetweenConversations() {
        XCTAssertEqual(TempleActionResolver.resolve(action: .musicPlayPause, context: TempleContext(activity: .standby)),
                       .run(.musicPlayPause))
        for activity: TempleContext.Activity in [.listening, .thinking, .speaking, .liveSession, .busy] {
            XCTAssertEqual(TempleActionResolver.resolve(action: .musicPlayPause, context: TempleContext(activity: activity)),
                           .ignored(.busy), "\(activity)")
        }
        XCTAssertEqual(TempleEarcon.for(.run(.musicPlayPause)), .accepted)
        XCTAssertEqual(TempleAction(rawValue: "musicPlayPause"), .musicPlayPause)
        XCTAssertTrue(TempleAction.builtIns.contains(.musicPlayPause))
    }

    func testTapOutcomeSeparatesDoneFromAQuestion() async {
        defaultProvider = .homeAssistant
        homeAssistant.players = [MusicFixtures.player("media_player.kitchen", name: "Kitchen"),
                                 MusicFixtures.player("media_player.lounge", name: "Lounge")]
        let environment = tool().makeEnvironment()
        let ask = await environment.execute(MusicToolRequest.parse(action: "toggle", args: [:]))
        XCTAssertEqual(ask.outcome, .needsInput)
        XCTAssertEqual(ask.spoken, "Which speaker: Kitchen or Lounge?")

        homeAssistant.players[1] = MusicFixtures.player("media_player.lounge", name: "Lounge", state: "playing")
        let toggled = await environment.execute(MusicToolRequest.parse(action: "toggle", args: [:]))
        XCTAssertEqual(toggled.outcome, .done)
        XCTAssertEqual(speaker.received.last?.1?.entityId, "media_player.lounge")
    }

    func testDescriptionTellsTheModelCatalogueFromLibraryAndNoSpotify() {
        let description = MusicControlTool().description
        XCTAssertTrue(description.contains("catalogue"))
        XCTAssertTrue(description.contains("library"))
        XCTAssertTrue(description.contains("cannot control Spotify"))
        XCTAssertFalse(description.contains("Plan "))
    }
}
