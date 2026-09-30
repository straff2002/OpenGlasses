import XCTest
@testable import OpenGlasses

/// Plan GS P0 — which provider a music command goes to.
final class MusicCommandRouterTests: XCTestCase {

    private typealias Router = MusicCommandRouter
    private let kitchen = MusicFixtures.kitchen
    private let lounge = MusicFixtures.lounge

    private func context(default provider: MusicProviderID = .appleMusic, usable: Bool = true,
                         speakers: [MusicSpeaker]? = nil, defaultSpeaker: String? = nil,
                         ask: Bool = true, applePlaying: Bool = false, playing: [String] = []) -> Router.Context {
        Router.Context(defaultProvider: provider, homeAssistantUsable: usable, homeAssistantUnavailableLine: nil,
                       speakers: speakers ?? [kitchen, lounge], defaultSpeakerEntityId: defaultSpeaker,
                       askWhenUnsure: ask, appleMusicPlaying: applePlaying, playingSpeakerEntityIds: playing)
    }

    private func play(_ phrase: String) -> MusicCommand {
        .playByName(MusicRequestParser.request(from: phrase))
    }

    func testNamedSpeakerWinsOverEverything() {
        let route = Router.route(.pause, target: .init(device: "kitchen"),
                                 context: context(applePlaying: true, playing: [lounge.entityId]))
        XCTAssertEqual(route, .homeAssistant(kitchen))
    }

    func testSpeakerNamesMatchByContainedWords() {
        XCTAssertEqual(Router.matchSpeaker("lounge", in: [kitchen, lounge]), lounge)
        XCTAssertEqual(Router.matchSpeaker("Kitchen", in: [kitchen, lounge]), kitchen)
        XCTAssertNil(Router.matchSpeaker("garage", in: [kitchen, lounge]))
    }

    func testUnknownSpeakerNamesTheAvailableOnes() {
        guard case .refuse(let line) = Router.route(.play, target: .init(device: "garage"), context: context()) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(line.contains("Kitchen and Lounge Sonos"), line)
    }

    func testSpotifyWithoutAHomeAssistantRouteGetsTheRefusal() {
        let route = Router.route(play("discover weekly"), target: .init(service: .unsupported("Spotify")),
                                 context: context(usable: false))
        XCTAssertEqual(route, .refuse(MusicPhraser.cannotControl("Spotify")))
        XCTAssertFalse(MusicPhraser.cannotControl("Spotify").contains("Plan"))
    }

    func testSpotifyWithAHomeAssistantDefaultGoesToTheSpeaker() {
        let route = Router.route(play("discover weekly"), target: .init(service: .unsupported("Spotify")),
                                 context: context(default: .homeAssistant, defaultSpeaker: kitchen.entityId))
        XCTAssertEqual(route, .homeAssistant(kitchen))
    }

    func testPlayingProviderBeatsTheDefault() {
        let speaker = Router.route(.next, target: .init(),
                                   context: context(default: .appleMusic, playing: [lounge.entityId]))
        XCTAssertEqual(speaker, .homeAssistant(lounge))
        let phone = Router.route(.pause, target: .init(),
                                 context: context(default: .homeAssistant, defaultSpeaker: kitchen.entityId, applePlaying: true))
        XCTAssertEqual(phone, .appleMusic)
    }

    func testBothPlayingTheDefaultBreaksTheTie() {
        let route = Router.route(.pause, target: .init(),
                                 context: context(default: .homeAssistant, applePlaying: true, playing: [kitchen.entityId]))
        XCTAssertEqual(route, .homeAssistant(kitchen))
    }

    func testUnusableHomeAssistantDefaultFallsBackToAppleMusic() {
        let route = Router.route(play("rumours"), target: .init(), context: context(default: .homeAssistant, usable: false))
        XCTAssertEqual(route, .appleMusic)
    }

    func testAmbiguousSpeakerAsksOrPicksPerSetting() {
        XCTAssertEqual(Router.route(play("rumours"), target: .init(), context: context(default: .homeAssistant)),
                       .askSpeaker([kitchen, lounge]))
        XCTAssertEqual(Router.route(play("rumours"), target: .init(), context: context(default: .homeAssistant, ask: false)),
                       .homeAssistant(kitchen))
    }

    func testWhatsPlayingNeverAsksWhichSpeaker() {
        XCTAssertEqual(Router.route(.nowPlaying, target: .init(), context: context(default: .homeAssistant)), .appleMusic)
    }

    func testCatalogueOperationsStayOnThePhone() {
        XCTAssertEqual(Router.route(.search("rumours"), target: .init(),
                                    context: context(default: .homeAssistant, defaultSpeaker: kitchen.entityId)),
                       .appleMusic)
        XCTAssertEqual(Router.route(.addToLibrary(nil), target: .init(device: "kitchen"), context: context()), .appleMusic)
    }

    func testNamedSpeakerWithoutHomeAssistantExplains() {
        XCTAssertEqual(Router.route(.play, target: .init(device: "kitchen"), context: context(usable: false)),
                       .refuse(MusicPhraser.speakersNeedHomeAssistant))
    }
}
