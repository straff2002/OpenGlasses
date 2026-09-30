import XCTest
@testable import OpenGlasses

/// Plan GS P1 — a Home Assistant media player as a music provider: request bodies, attribute
/// parsing, and honest answers for what a speaker does not advertise.
@MainActor
final class HomeAssistantMusicProviderTests: XCTestCase {

    private let kitchen = MusicFixtures.kitchen

    private func provider(_ players: [HomeAssistantMediaPlayer]) -> (HomeAssistantMusicProvider, FakeHomeAssistant) {
        let fake = FakeHomeAssistant()
        fake.players = players
        return (HomeAssistantMusicProvider(client: fake), fake)
    }

    func testTransportCallsTheMatchingMediaPlayerServices() async {
        let (music, fake) = provider([MusicFixtures.player(kitchen.entityId, name: "Kitchen", state: "playing")])
        _ = await music.perform(.pause, speaker: kitchen)
        _ = await music.perform(.next, speaker: kitchen)
        let toggled = await music.perform(.toggle, speaker: kitchen)
        XCTAssertEqual(fake.calls.map(\.service), ["media_pause", "media_next_track", "media_play_pause"])
        XCTAssertEqual(Set(fake.calls.map(\.entityId)), [kitchen.entityId])
        XCTAssertEqual(Set(fake.calls.map(\.domain)), ["media_player"])
        XCTAssertEqual(toggled.spoken, "Paused on Kitchen.")
    }

    func testPlayMediaCarriesOnlyAllowlistedData() async {
        let (music, fake) = provider([MusicFixtures.player(kitchen.entityId, name: "Kitchen")])
        let request = MusicRequestParser.request(from: "my Discover Weekly playlist")
        let result = await music.perform(.playByName(request), speaker: kitchen)
        XCTAssertEqual(result.outcome, .done)
        let body = fake.calls.first?.data.body(entityId: kitchen.entityId)
        XCTAssertEqual(body?["media_content_id"] as? String, "discover weekly")
        XCTAssertEqual(body?["media_content_type"] as? String, "playlist")
        XCTAssertEqual(body?["entity_id"] as? String, kitchen.entityId)
        XCTAssertEqual(body?.count, 3)
    }

    func testSpeakerWithoutPlayMediaIsToldNotCalled() async {
        let (music, fake) = provider([MusicFixtures.player(kitchen.entityId, name: "Kitchen", features: [.pause, .play])])
        let result = await music.perform(.playByName(MusicRequestParser.request(from: "rumours")), speaker: kitchen)
        XCTAssertEqual(result.outcome, .unsupported)
        XCTAssertEqual(result.spoken, "Kitchen doesn't support playing music by name.")
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testVolumeStepsThroughVolumeSetWhenThereIsNoStepService() async {
        let (music, fake) = provider([MusicFixtures.player(kitchen.entityId, name: "Kitchen", volume: 0.4)])
        _ = await music.perform(.volumeUp, speaker: kitchen)
        XCTAssertEqual(fake.calls.first?.service, "volume_set")
        guard case .number(let level)? = fake.calls.first?.data.values["volume_level"] else {
            return XCTFail("expected a volume level")
        }
        XCTAssertEqual(level, 0.5, accuracy: 0.0001)
    }

    func testVolumeSetClampsAndSpeaksAPercentage() async {
        let (music, fake) = provider([MusicFixtures.player(kitchen.entityId, name: "Kitchen")])
        let result = await music.perform(.volumeSet(0.3), speaker: kitchen)
        XCTAssertEqual(result.spoken, "Volume set to 30 percent on Kitchen.")
        XCTAssertEqual(fake.calls.first?.data.values["volume_level"], .number(0.3))
    }

    func testNowPlayingReadsTheEntityAttributes() async {
        let json: [String: Any] = [
            "entity_id": "media_player.kitchen",
            "state": "playing",
            "attributes": [
                "friendly_name": "Kitchen",
                "media_title": "Dreams",
                "media_artist": "Fleetwood Mac",
                "media_album_name": "Rumours",
                "app_name": "Spotify",
                "volume_level": 0.35,
                "supported_features": 152_511,
                "media_position": 62,
                "media_duration": 257,
            ] as [String: Any],
        ]
        let player = try? XCTUnwrap(HomeAssistantMediaPlayer.parse(json))
        XCTAssertEqual(player?.title, "Dreams")
        XCTAssertEqual(player?.volume, 0.35)
        XCTAssertTrue(player?.supportedFeatures.contains(.playMedia) ?? false)
        XCTAssertEqual(MusicPhraser.nowPlaying(player?.nowPlaying),
                       "Playing Dreams by Fleetwood Mac, from Rumours on Kitchen through Spotify — 1 minute 2 in, of 4 minutes 17.")
    }

    func testStatesParsingKeepsOnlyMediaPlayers() {
        let states: [[String: Any]] = [
            ["entity_id": "light.kitchen", "state": "on", "attributes": ["friendly_name": "Kitchen Light"]],
            ["entity_id": "media_player.lounge_sonos", "state": "idle", "attributes": [:] as [String: Any]],
            ["entity_id": "media_player.kitchen", "state": "PAUSED", "attributes": ["friendly_name": "Kitchen"]],
        ]
        let players = HomeAssistantMediaPlayer.parseStates(states)
        XCTAssertEqual(players.map(\.name), ["Kitchen", "Lounge Sonos"])
        XCTAssertEqual(players.first?.state, "paused")
    }

    func testUnreachableHomeAssistantIsOneSentence() async {
        let fake = FakeHomeAssistant()
        fake.failure = URLError(.cannotConnectToHost)
        let result = await HomeAssistantMusicProvider(client: fake).perform(.pause, speaker: kitchen)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.spoken, "Home Assistant didn't answer. Check that it's reachable from your phone.")
    }
}
