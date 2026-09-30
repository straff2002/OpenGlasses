import XCTest
@testable import OpenGlasses

/// Plan GS — choosing the catalogue result to play: exact beats popular, a named artist counts,
/// an explicit kind filters.
final class MusicCatalogRankerTests: XCTestCase {

    func testExactTitleBeatsAMorePopularPartialMatch() {
        let request = MusicRequestParser.request(from: "Yesterday", kind: .song)
        let candidates = [
            MusicFixtures.song("Yesterday Once More", by: "Carpenters", rank: 0),
            MusicFixtures.song("Yesterday - Remastered 2009", by: "The Beatles", rank: 3),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.artist, "The Beatles")
    }

    func testNamedArtistBeatsAMorePopularCover() {
        let request = MusicRequestParser.request(from: "Hallelujah by Jeff Buckley")
        let candidates = [
            MusicFixtures.song("Hallelujah", by: "Pentatonix", rank: 0),
            MusicFixtures.song("Hallelujah", by: "Jeff Buckley", rank: 4),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.artist, "Jeff Buckley")
    }

    func testTitleContainingByStillMatchesAsAWholeTitle() {
        let request = MusicRequestParser.request(from: "Stand by Me")
        let candidates = [
            MusicFixtures.song("Stand", by: "R.E.M.", rank: 0),
            MusicFixtures.song("Stand by Me", by: "Ben E. King", rank: 1),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.title, "Stand by Me")
    }

    func testExplicitAlbumHintFiltersOutSongs() {
        let request = MusicRequestParser.request(from: "the album Rumours")
        let candidates = [
            MusicFixtures.item(.song, "Rumours", artist: "Someone", rank: 0),
            MusicFixtures.item(.album, "Rumours", artist: "Fleetwood Mac", rank: 0),
        ]
        let best = MusicCatalogRanker.best(for: request, among: candidates)
        XCTAssertEqual(best?.kind, .album)
        XCTAssertEqual(MusicCatalogRanker.ranked(for: request, among: candidates).count, 1)
    }

    func testPlaylistHintPicksThePlaylist() {
        let request = MusicRequestParser.request(from: "chill vibes playlist")
        let candidates = [
            MusicFixtures.item(.song, "Chill Vibes", artist: "DJ", rank: 0),
            MusicFixtures.item(.playlist, "Chill Vibes", artist: "Apple Music", rank: 2),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.kind, .playlist)
    }

    func testAnArtistsExactNameWinsWithNoKindGiven() {
        let request = MusicRequestParser.request(from: "Radiohead")
        let candidates = [
            MusicFixtures.song("Creep", by: "Radiohead", rank: 0),
            MusicFixtures.item(.artist, "Radiohead", rank: 0),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.kind, .artist)
    }

    func testNothingCloseMeansNothingPlays() {
        let request = MusicRequestParser.request(from: "zyxwv qqq", kind: .song)
        XCTAssertNil(MusicCatalogRanker.best(for: request, among: [MusicFixtures.song("Hello", by: "Adele")]))
    }

    func testPopularityBreaksTies() {
        let request = MusicRequestParser.request(from: "Hello", kind: .song)
        let candidates = [
            MusicFixtures.song("Hello", by: "Lionel Richie", rank: 2),
            MusicFixtures.song("Hello", by: "Adele", rank: 0),
        ]
        XCTAssertEqual(MusicCatalogRanker.best(for: request, among: candidates)?.artist, "Adele")
    }

    func testComparableStripsEditionTags() {
        XCTAssertEqual(MusicCatalogRanker.comparable("Let It Be (Remastered 2009)"), "let it be")
        XCTAssertEqual(MusicCatalogRanker.comparable("Yesterday - Remastered 2009"), "yesterday")
        XCTAssertEqual(MusicCatalogRanker.comparable("Blinding Lights - Single"), "blinding lights")
        XCTAssertEqual(MusicCatalogRanker.comparable("Don't Stop Me Now"), "dont stop me now")
    }
}
