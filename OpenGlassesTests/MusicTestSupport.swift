import Foundation
@testable import OpenGlasses

// Plan GS — fakes for the music seams. Nothing here touches MediaPlayer, MusicKit or a network.

@MainActor
final class FakeMusicLibrary: MusicLibraryPlaying {
    var playing = false
    var current: NowPlayingSummary?
    var calls: [String] = []
    var searchResults: [MusicLibraryMatch] = []
    /// What `play(_:)` returns; nil means nothing in the library matched.
    var playResult: MusicLibraryMatch?
    var playedRequests: [MusicPlayRequest] = []

    func play() { calls.append("play"); playing = true }
    func pause() { calls.append("pause"); playing = false }
    var isPlaying: Bool { playing }
    func skipToNext() { calls.append("next") }
    func skipToPrevious() { calls.append("previous") }
    func shuffleAll() { calls.append("shuffleAll") }
    func nowPlaying() -> NowPlayingSummary? { current }
    func search(_ query: String, limit: Int) -> [MusicLibraryMatch] { Array(searchResults.prefix(limit)) }
    func play(_ request: MusicPlayRequest) -> MusicLibraryMatch? {
        playedRequests.append(request)
        return playResult
    }
}

@MainActor
final class FakeMusicCatalog: MusicCatalogServing {
    var authorizationStatus: MusicAccessStatus = .authorized
    var statusAfterRequest: MusicAccessStatus = .authorized
    var subscription: Bool? = true
    var results: [MusicCatalogCandidate] = []
    var searchError: MusicCatalogFailure?
    var addError: MusicCatalogFailure?
    var songsByID: [String: MusicCatalogCandidate] = [:]

    private(set) var requestedAuthorization = 0
    private(set) var searches: [(term: String, kinds: [MusicItemKind])] = []
    private(set) var played: [(MusicCatalogCandidate, Bool)] = []
    private(set) var added: [MusicCatalogCandidate] = []

    func requestAuthorization() async -> MusicAccessStatus {
        requestedAuthorization += 1
        authorizationStatus = statusAfterRequest
        return statusAfterRequest
    }
    func canPlayCatalogContent() async -> Bool? { subscription }
    func search(term: String, kinds: [MusicItemKind], limit: Int) async throws -> [MusicCatalogCandidate] {
        searches.append((term, kinds))
        if let searchError { throw searchError }
        return results.filter { kinds.contains($0.kind) }
    }
    func play(_ candidate: MusicCatalogCandidate, shuffle: Bool) async throws { played.append((candidate, shuffle)) }
    func addToLibrary(_ candidate: MusicCatalogCandidate) async throws {
        if let addError { throw addError }
        added.append(candidate)
    }
    func song(catalogID: String) async throws -> MusicCatalogCandidate? { songsByID[catalogID] }
}

/// Records Home Assistant calls and serves canned media-player states.
final class FakeHomeAssistant: HomeAssistantServiceCalling, @unchecked Sendable {
    struct Call: Equatable {
        let domain: String
        let service: String
        let entityId: String
        let data: HomeAssistantServiceData
    }

    var isConfigured = true
    var players: [HomeAssistantMediaPlayer] = []
    var failure: Error?
    private(set) var calls: [Call] = []
    private(set) var stateFetches = 0

    func callService(domain: String, service: String, entityId: String,
                     data: HomeAssistantServiceData) async throws {
        if let failure { throw failure }
        calls.append(Call(domain: domain, service: service, entityId: entityId, data: data))
    }
    func mediaPlayers() async throws -> [HomeAssistantMediaPlayer] {
        stateFetches += 1
        if let failure { throw failure }
        return players
    }
    func mediaPlayer(entityId: String) async throws -> HomeAssistantMediaPlayer? {
        if let failure { throw failure }
        return players.first { $0.entityId == entityId }
    }
}

/// A controllable provider for the tool tests.
@MainActor
final class RecordingMusicProvider: MusicProvider {
    let id: MusicProviderID
    let capabilities: Set<MusicCapability> = Set(MusicCapability.allCases)
    var reply = MusicCommandResult.done("ok")
    private(set) var received: [(MusicCommand, MusicSpeaker?)] = []

    init(id: MusicProviderID) { self.id = id }

    func perform(_ command: MusicCommand, speaker: MusicSpeaker?) async -> MusicCommandResult {
        received.append((command, speaker))
        return reply
    }
    func nowPlaying(speaker: MusicSpeaker?) async -> NowPlayingSummary? { nil }
}

enum MusicFixtures {
    static func player(_ entityId: String, name: String, state: String = "idle",
                       features: HomeAssistantMediaPlayer.Features = [.pause, .play, .nextTrack, .previousTrack, .volumeSet, .playMedia],
                       volume: Double? = 0.4, title: String? = nil, artist: String? = nil) -> HomeAssistantMediaPlayer {
        HomeAssistantMediaPlayer(entityId: entityId, name: name, state: state, title: title, artist: artist,
                                 album: nil, volume: volume, supportedFeatures: features, appName: nil,
                                 position: nil, duration: nil)
    }

    static func song(_ title: String, by artist: String, rank: Int = 0, id: String? = nil) -> MusicCatalogCandidate {
        MusicCatalogCandidate(id: id ?? "song-\(title)-\(artist)", kind: .song, title: title, artist: artist, popularityRank: rank)
    }

    static func item(_ kind: MusicItemKind, _ title: String, artist: String? = nil, rank: Int = 0) -> MusicCatalogCandidate {
        MusicCatalogCandidate(id: "\(kind.rawValue)-\(title)", kind: kind, title: title, artist: artist, popularityRank: rank)
    }

    static let kitchen = MusicSpeaker(entityId: "media_player.kitchen", name: "Kitchen")
    static let lounge = MusicSpeaker(entityId: "media_player.lounge_sonos", name: "Lounge Sonos")
}
