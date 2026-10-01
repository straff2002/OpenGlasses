import Foundation
@preconcurrency import MusicKit

/// The production `MusicCatalogServing`: the Apple Music catalogue through MusicKit (Plan GS).
///
/// **Player choice: `SystemMusicPlayer`, deliberately not `ApplicationMusicPlayer`.**
/// - The system player plays in the Music app's process. Playback survives Avenkin being
///   backgrounded, suspended or killed and the phone locking, with no background-audio work of
///   our own and nothing on Avenkin's audio session.
/// - Avenkin's audio session belongs to the wake-word listener, speech output and the temple-tap
///   claim. An application player would put the wearer's music on that same session, where every
///   spoken reply and every listening turn would have to duck or interrupt it, and where the
///   temple-tap trigger would see no "other audio" and could claim Now Playing over the wearer's
///   own music. With the system player, the Music app owns Now Playing: the trigger's policy sees
///   other audio and stands down (and `music_control` posts `userPlaybackRequested` before every
///   command so it stands down first), and the glasses' temple controls go straight to Music.
/// - It is the same player the library path drives through MediaPlayer, so "pause", "skip" and
///   "what's playing" work identically whichever path started the music.
///
/// The catalogue's developer token comes from the MusicKit App Service on the App ID; no key is
/// shipped. Search terms go to Apple's servers — see the privacy policy's Apple row.
@MainActor
final class MusicKitCatalog: MusicCatalogServing {

    /// The typed items behind the last search, so a flattened candidate can be played or added.
    private enum Item {
        case song(Song), album(Album), artist(Artist), playlist(Playlist), station(Station)
    }
    private var items: [String: Item] = [:]

    // MARK: - Access

    var authorizationStatus: MusicAccessStatus { Self.map(MusicAuthorization.currentStatus) }

    func requestAuthorization() async -> MusicAccessStatus {
        Self.map(await MusicAuthorization.request())
    }

    func canPlayCatalogContent() async -> Bool? {
        do {
            return try await MusicSubscription.current.canPlayCatalogContent
        } catch {
            return nil
        }
    }

    static func map(_ status: MusicAuthorization.Status) -> MusicAccessStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    // MARK: - Search

    func search(term: String, kinds: [MusicItemKind], limit: Int) async throws -> [MusicCatalogCandidate] {
        let types: [any MusicCatalogSearchable.Type] = kinds.compactMap { kind in
            switch kind {
            case .song: return Song.self
            case .album: return Album.self
            case .artist: return Artist.self
            case .playlist: return Playlist.self
            case .station: return Station.self
            case .any: return nil
            }
        }
        guard !types.isEmpty else { return [] }
        var request = MusicCatalogSearchRequest(term: term, types: types)
        request.limit = max(1, min(limit, 25))
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            throw Self.failure(error)
        }

        items.removeAll()
        var candidates: [MusicCatalogCandidate] = []
        for (rank, song) in response.songs.enumerated() {
            items[song.id.rawValue] = .song(song)
            candidates.append(.init(id: song.id.rawValue, kind: .song, title: song.title,
                                    artist: song.artistName, popularityRank: rank))
        }
        for (rank, album) in response.albums.enumerated() {
            items[album.id.rawValue] = .album(album)
            candidates.append(.init(id: album.id.rawValue, kind: .album, title: album.title,
                                    artist: album.artistName, popularityRank: rank))
        }
        for (rank, artist) in response.artists.enumerated() {
            items[artist.id.rawValue] = .artist(artist)
            candidates.append(.init(id: artist.id.rawValue, kind: .artist, title: artist.name,
                                    artist: nil, popularityRank: rank))
        }
        for (rank, playlist) in response.playlists.enumerated() {
            items[playlist.id.rawValue] = .playlist(playlist)
            candidates.append(.init(id: playlist.id.rawValue, kind: .playlist, title: playlist.name,
                                    artist: playlist.curatorName, popularityRank: rank))
        }
        for (rank, station) in response.stations.enumerated() {
            items[station.id.rawValue] = .station(station)
            candidates.append(.init(id: station.id.rawValue, kind: .station, title: station.name,
                                    artist: nil, popularityRank: rank))
        }
        return candidates
    }

    func song(catalogID: String) async throws -> MusicCatalogCandidate? {
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
        let response: MusicCatalogResourceResponse<Song>
        do {
            response = try await request.response()
        } catch {
            throw Self.failure(error)
        }
        guard let song = response.items.first else { return nil }
        items[song.id.rawValue] = .song(song)
        return MusicCatalogCandidate(id: song.id.rawValue, kind: .song, title: song.title,
                                     artist: song.artistName, popularityRank: 0)
    }

    // MARK: - Play

    func play(_ candidate: MusicCatalogCandidate, shuffle: Bool) async throws {
        guard let item = items[candidate.id] else { throw MusicCatalogFailure.notFound }
        let player = SystemMusicPlayer.shared
        switch item {
        case .song(let song): player.queue = [song]
        case .album(let album): player.queue = [album]
        case .playlist(let playlist): player.queue = [playlist]
        case .station(let station): player.queue = [station]
        case .artist(let artist):
            // An artist is not playable itself: their top songs, else their station.
            let detailed = try await artist.with([.topSongs, .station])
            if let songs = detailed.topSongs, !songs.isEmpty {
                player.queue = MusicPlayer.Queue(for: songs)
            } else if let station = detailed.station {
                player.queue = [station]
            } else {
                throw MusicCatalogFailure.notFound
            }
        }
        player.state.shuffleMode = shuffle ? .songs : .off
        try await player.play()
    }

    // MARK: - Library

    func addToLibrary(_ candidate: MusicCatalogCandidate) async throws {
        guard let item = items[candidate.id] else { throw MusicCatalogFailure.notFound }
        do {
            switch item {
            case .song(let song): try await MusicLibrary.shared.add(song)
            case .album(let album): try await MusicLibrary.shared.add(album)
            case .playlist(let playlist): try await MusicLibrary.shared.add(playlist)
            case .artist, .station: throw MusicCatalogFailure.notFound
            }
        } catch let error as MusicCatalogFailure {
            throw error
        } catch {
            throw Self.failure(error)
        }
    }

    // MARK: - Errors

    private static func failure(_ error: Error) -> MusicCatalogFailure {
        if let libraryError = error as? MusicLibrary.Error {
            switch libraryError {
            case .itemAlreadyAdded: return .alreadyInLibrary
            case .permissionDenied: return .notAuthorized
            default: return .unavailable
            }
        }
        if let subscriptionError = error as? MusicSubscription.Error {
            switch subscriptionError {
            case .permissionDenied, .privacyAcknowledgementRequired: return .notAuthorized
            default: return .unavailable
            }
        }
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .permissionDenied, .userNotSignedIn, .privacyAcknowledgementRequired: return .notAuthorized
            default: return .unavailable
            }
        }
        return .unavailable
    }
}
