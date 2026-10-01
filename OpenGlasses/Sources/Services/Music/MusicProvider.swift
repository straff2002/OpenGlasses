import Foundation

/// One place music can be controlled from (Plan GS P0).
///
/// `speaker` is the Home Assistant media player a route chose; Apple Music ignores it.
@MainActor
protocol MusicProvider: AnyObject {
    var id: MusicProviderID { get }
    var capabilities: Set<MusicCapability> { get }
    func perform(_ command: MusicCommand, speaker: MusicSpeaker?) async -> MusicCommandResult
    func nowPlaying(speaker: MusicSpeaker?) async -> NowPlayingSummary?
}

// MARK: - Seams

/// The wearer's library and the Music app's transport, through MediaPlayer. The production
/// conformance is `MediaPlayerLibrary`; tests use a fake so nothing touches the Music app.
@MainActor
protocol MusicLibraryPlaying: AnyObject {
    func play()
    func pause()
    var isPlaying: Bool { get }
    func skipToNext()
    func skipToPrevious()
    /// Shuffle the whole library and play.
    func shuffleAll()
    /// What the Music app has loaded, library or catalogue.
    func nowPlaying() -> NowPlayingSummary?
    /// Find songs whose title or artist contains the words, for the "search" action.
    func search(_ query: String, limit: Int) -> [MusicLibraryMatch]
    /// Queue and play the best library match for the request; nil when nothing matched.
    func play(_ request: MusicPlayRequest) -> MusicLibraryMatch?
}

/// The Apple Music catalogue, through MusicKit. The production conformance is
/// `MusicKitCatalog`; tests use a fake, so no test ever reaches MusicKit or Apple's servers.
@MainActor
protocol MusicCatalogServing: AnyObject {
    var authorizationStatus: MusicAccessStatus { get }
    /// Shows the system prompt. Only called while the app is in the foreground.
    func requestAuthorization() async -> MusicAccessStatus
    /// Whether this account can stream catalogue content; nil when the check failed.
    func canPlayCatalogContent() async -> Bool?
    func search(term: String, kinds: [MusicItemKind], limit: Int) async throws -> [MusicCatalogCandidate]
    /// Queue the candidate on the system player and start it.
    func play(_ candidate: MusicCatalogCandidate, shuffle: Bool) async throws
    func addToLibrary(_ candidate: MusicCatalogCandidate) async throws
    /// Resolve a catalogue id (from what is playing) to a song candidate.
    func song(catalogID: String) async throws -> MusicCatalogCandidate?
}
