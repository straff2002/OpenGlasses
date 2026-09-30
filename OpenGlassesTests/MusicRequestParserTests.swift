import XCTest
@testable import OpenGlasses

/// Plan GS — spoken music requests → a kind, a title/artist reading, and a target.
final class MusicRequestParserTests: XCTestCase {

    func testExplicitAlbumHintAndArtistSplit() {
        let request = MusicRequestParser.request(from: "the album Rumours by Fleetwood Mac")
        XCTAssertEqual(request.kind, .album)
        XCTAssertEqual(request.title, "rumours")
        XCTAssertEqual(request.artist, "fleetwood mac")
        XCTAssertEqual(request.phrase, "rumours by fleetwood mac")
    }

    func testTrailingPlaylistHintDropsThePossessive() {
        let request = MusicRequestParser.request(from: "my Discover Weekly playlist")
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertEqual(request.phrase, "discover weekly")
    }

    func testRadioAndStationWordsMeanAStation() {
        XCTAssertEqual(MusicRequestParser.request(from: "jazz radio").kind, .station)
        XCTAssertEqual(MusicRequestParser.request(from: "jazz radio").phrase, "jazz")
        XCTAssertEqual(MusicRequestParser.request(from: "the station Beats 1").kind, .station)
    }

    func testSongsByMeansTheArtistShuffled() {
        let request = MusicRequestParser.request(from: "play some songs by Taylor Swift")
        XCTAssertEqual(request.kind, .artist)
        XCTAssertEqual(request.phrase, "taylor swift")
        XCTAssertNil(request.artist)
        XCTAssertTrue(request.shuffle)
    }

    func testActionKindWinsOverPhraseAndApostrophesSurviveForSearch() {
        let request = MusicRequestParser.request(from: "Don't Stop Me Now", kind: .song)
        XCTAssertEqual(request.kind, .song)
        XCTAssertEqual(request.searchTerm, "don't stop me now")
    }

    func testByWithoutAnArtistKeepsTheWholePhraseAsAReading() {
        // "Stand by Me" is a title; the ranker scores both readings and keeps the better.
        let request = MusicRequestParser.request(from: "Stand by Me")
        XCTAssertEqual(request.phrase, "stand by me")
        XCTAssertEqual(request.title, "stand")
        XCTAssertEqual(request.artist, "me")
    }

    func testTargetOnANamedSpeaker() {
        let (rest, target) = MusicRequestParser.extractTarget(from: "Hotel California on the living room speaker")
        XCTAssertEqual(rest, "hotel california")
        XCTAssertEqual(target.device, "living room")
        XCTAssertNil(target.service)
    }

    func testTargetOnSpotifyIsAnUnsupportedService() {
        let (rest, target) = MusicRequestParser.extractTarget(from: "Discover Weekly on Spotify")
        XCTAssertEqual(rest, "discover weekly")
        XCTAssertEqual(target.service, .unsupported("Spotify"))
    }

    func testInsideATitleIsNotATarget() {
        let (rest, target) = MusicRequestParser.extractTarget(from: "In the Air Tonight")
        XCTAssertEqual(rest, "in the air tonight")
        XCTAssertEqual(target, MusicRequestParser.Target())
        let (onRest, onTarget) = MusicRequestParser.extractTarget(from: "Walking on Sunshine")
        XCTAssertEqual(onRest, "walking on sunshine")
        XCTAssertEqual(onTarget, MusicRequestParser.Target())
    }

    func testServiceArgumentNames() {
        XCTAssertEqual(MusicRequestParser.service(named: "apple_music"), .appleMusic)
        XCTAssertEqual(MusicRequestParser.service(named: "Home Assistant"), .homeAssistant)
        XCTAssertEqual(MusicRequestParser.service(named: "spotify"), .unsupported("Spotify"))
        XCTAssertEqual(MusicRequestParser.service(named: "YouTube Music"), .unsupported("YouTube Music"))
        XCTAssertNil(MusicRequestParser.service(named: "kitchen"))
    }
}
