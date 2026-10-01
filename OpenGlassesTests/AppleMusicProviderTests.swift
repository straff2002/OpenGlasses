import XCTest
@testable import OpenGlasses

/// Plan GS — Apple Music: catalogue when subscribed, library otherwise, never a dead end.
/// Both seams are fakes; nothing reaches MediaPlayer or MusicKit.
@MainActor
final class AppleMusicProviderTests: XCTestCase {

    private var library: FakeMusicLibrary!
    private var catalog: FakeMusicCatalog!
    private var localOnly = false
    private var foreground = true

    override func setUp() async throws {
        library = FakeMusicLibrary()
        catalog = FakeMusicCatalog()
        localOnly = false
        foreground = true
    }

    private func provider() -> AppleMusicProvider {
        AppleMusicProvider(library: library, catalog: catalog,
                           catalogueAllowed: { [unowned self] in !self.localOnly },
                           canPromptForAccess: { [unowned self] in self.foreground })
    }

    private func play(_ phrase: String, kind: MusicItemKind = .any) async -> MusicCommandResult {
        await provider().perform(.playByName(MusicRequestParser.request(from: phrase, kind: kind)), speaker: nil)
    }

    func testSubscriberPlaysTheBestCatalogueMatch() async {
        catalog.results = [MusicFixtures.song("Hallelujah", by: "Pentatonix", rank: 0),
                           MusicFixtures.song("Hallelujah", by: "Jeff Buckley", rank: 1)]
        let result = await play("Hallelujah by Jeff Buckley")
        XCTAssertEqual(result, .done("Playing Hallelujah by Jeff Buckley."))
        XCTAssertEqual(catalog.played.first?.0.artist, "Jeff Buckley")
        XCTAssertTrue(library.playedRequests.isEmpty, "the library is not touched when the catalogue plays")
    }

    func testExplicitKindNarrowsTheCatalogueSearch() async {
        catalog.results = [MusicFixtures.item(.album, "Rumours", artist: "Fleetwood Mac")]
        _ = await play("Rumours", kind: .album)
        XCTAssertEqual(catalog.searches.first?.kinds, [.album])
        XCTAssertEqual(catalog.played.first?.0.kind, .album)
    }

    func testArtistPlaysShuffled() async {
        catalog.results = [MusicFixtures.item(.artist, "Radiohead")]
        _ = await play("Radiohead", kind: .artist)
        XCTAssertEqual(catalog.played.first?.1, true)
    }

    func testNoSubscriptionPlaysFromTheLibrary() async {
        catalog.subscription = false
        library.playResult = MusicLibraryMatch(kind: .song, title: "Rumours", artist: "Fleetwood Mac", trackCount: 1)
        let result = await play("Rumours")
        XCTAssertEqual(result.outcome, .done)
        XCTAssertTrue(catalog.searches.isEmpty, "no catalogue search without a subscription")
        XCTAssertEqual(library.playedRequests.count, 1)
    }

    func testNoSubscriptionAndNoLibraryMatchSaysWhyInOneSentence() async {
        catalog.subscription = false
        let result = await play("Rumours")
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertTrue(result.spoken.contains("needs an Apple Music subscription"), result.spoken)
        XCTAssertEqual(result.spoken.filter { $0 == "." }.count, 1, result.spoken)
    }

    func testCatalogueMissFallsThroughToTheLibrary() async {
        catalog.results = [MusicFixtures.song("Something Else", by: "Nobody")]
        library.playResult = MusicLibraryMatch(kind: .song, title: "Home Demo", artist: nil, trackCount: 1)
        let result = await play("Home Demo")
        XCTAssertEqual(result, .done("Playing Home Demo from your library."))
    }

    func testCatalogueErrorFallsThroughToTheLibrary() async {
        catalog.searchError = .unavailable
        library.playResult = MusicLibraryMatch(kind: .artist, title: "Queen", artist: nil, trackCount: 40)
        let result = await play("Queen", kind: .artist)
        XCTAssertEqual(result, .done("Shuffling 40 songs by Queen from your library."))
    }

    func testMedicalLocalOnlyKeepsSearchTermsOnThePhone() async {
        localOnly = true
        catalog.results = [MusicFixtures.song("Rumours", by: "Fleetwood Mac")]
        let result = await play("Rumours")
        XCTAssertTrue(catalog.searches.isEmpty)
        XCTAssertTrue(result.spoken.contains("Medical Local Only"), result.spoken)
    }

    func testAccessIsAskedForOnlyInTheForeground() async {
        catalog.authorizationStatus = .notDetermined
        foreground = false
        let background = await play("Rumours")
        XCTAssertEqual(catalog.requestedAuthorization, 0)
        XCTAssertEqual(background.spoken, MusicPhraser.accessNeedsPhone)

        foreground = true
        catalog.results = [MusicFixtures.song("Rumours", by: "Fleetwood Mac")]
        let foregroundResult = await play("Rumours")
        XCTAssertEqual(catalog.requestedAuthorization, 1)
        XCTAssertEqual(foregroundResult.outcome, .done)
    }

    func testDeniedAccessPointsToSettings() async {
        catalog.authorizationStatus = .denied
        let result = await play("Rumours")
        XCTAssertEqual(result.spoken, MusicPhraser.accessDenied)
    }

    func testAddWhatIsPlayingToTheLibrary() async {
        library.current = NowPlayingSummary(title: "Blinding Lights", artist: "The Weeknd", state: .playing,
                                            provider: .appleMusic, catalogID: "1488408568")
        catalog.songsByID["1488408568"] = MusicFixtures.song("Blinding Lights", by: "The Weeknd", id: "1488408568")
        let result = await provider().perform(.addToLibrary(nil), speaker: nil)
        XCTAssertEqual(result, .done("Added Blinding Lights by The Weeknd to your library."))
        XCTAssertEqual(catalog.added.map(\.id), ["1488408568"])
    }

    func testAddingSomethingAlreadyThereSaysSo() async {
        catalog.results = [MusicFixtures.song("Rumours", by: "Fleetwood Mac")]
        catalog.addError = .alreadyInLibrary
        let result = await provider().perform(.addToLibrary(MusicRequestParser.request(from: "Rumours")), speaker: nil)
        XCTAssertEqual(result, .done("Rumours is already in your library."))
    }

    func testAddingNeedsASubscription() async {
        catalog.subscription = false
        let result = await provider().perform(.addToLibrary(nil), speaker: nil)
        XCTAssertEqual(result.spoken, MusicPhraser.addNeedsSubscription)
    }

    func testTransportUsesTheLibraryPlayerUnchanged() async {
        library.current = NowPlayingSummary(title: "Creep", artist: "Radiohead", state: .playing, provider: .appleMusic)
        let apple = provider()
        let skipped = await apple.perform(.next, speaker: nil)
        XCTAssertEqual(skipped, .done("Skipped to Creep by Radiohead."))
        let paused = await apple.perform(.pause, speaker: nil)
        XCTAssertEqual(paused, .done("Music paused."))
        _ = await apple.perform(.toggle, speaker: nil)
        _ = await apple.perform(.shuffle, speaker: nil)
        XCTAssertEqual(library.calls, ["next", "pause", "play", "shuffleAll"])
        let volume = await apple.perform(.volumeUp, speaker: nil)
        XCTAssertEqual(volume.outcome, .unsupported)
    }
}
