import Foundation
@preconcurrency import MediaPlayer

/// The production `MusicLibraryPlaying`: the wearer's own library and the Music app's transport,
/// through MediaPlayer's system player (Plan GS). This is the body `music_control` always had,
/// moved behind the seam; picking a match now goes through `MusicCatalogRanker`, so an exact
/// title beats the first "contains" hit.
@MainActor
final class MediaPlayerLibrary: MusicLibraryPlaying {

    private var player: MPMusicPlayerController { .systemMusicPlayer }

    // MARK: - Transport

    func play() { player.play() }
    func pause() { player.pause() }
    var isPlaying: Bool { player.playbackState == .playing }
    func skipToNext() { player.skipToNextItem() }
    func skipToPrevious() { player.skipToPreviousItem() }

    func shuffleAll() {
        player.shuffleMode = .songs
        player.play()
    }

    func nowPlaying() -> NowPlayingSummary? {
        guard let item = player.nowPlayingItem else { return nil }
        let state: NowPlayingSummary.State
        switch player.playbackState {
        case .playing, .seekingForward, .seekingBackward: state = .playing
        case .paused, .interrupted: state = .paused
        case .stopped: state = .stopped
        @unknown default: state = .paused
        }
        let storeID = item.playbackStoreID
        let elapsed = player.currentPlaybackTime
        return NowPlayingSummary(
            title: item.title,
            artist: item.artist,
            album: item.albumTitle,
            releaseYear: item.releaseDate.map { Calendar.current.component(.year, from: $0) },
            state: state,
            elapsed: elapsed.isFinite ? elapsed : nil,
            duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
            provider: .appleMusic,
            catalogID: storeID.isEmpty || storeID == "0" ? nil : storeID)
    }

    // MARK: - Library search

    func search(_ query: String, limit: Int) -> [MusicLibraryMatch] {
        var seen = Set<MPMediaEntityPersistentID>()
        var matches: [MusicLibraryMatch] = []
        for property in [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist] {
            for item in songs(where: property, contains: query) where seen.insert(item.persistentID).inserted {
                matches.append(MusicLibraryMatch(kind: .song, title: item.title ?? "Unknown",
                                                 artist: item.artist, trackCount: 1))
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    // MARK: - Play by name

    func play(_ request: MusicPlayRequest) -> MusicLibraryMatch? {
        switch request.kind {
        case .song: return playSong(request)
        case .artist: return playArtist(request.phrase)
        case .album: return playAlbum(request)
        case .playlist: return playPlaylist(request)
        case .station: return nil
        case .any:
            return playSong(request) ?? playArtist(request.phrase) ?? playAlbum(request) ?? playPlaylist(request)
        }
    }

    private func playSong(_ request: MusicPlayRequest) -> MusicLibraryMatch? {
        var seen = Set<MPMediaEntityPersistentID>()
        var items: [MPMediaItem] = []
        for term in Set([request.title, request.phrase]) {
            for item in songs(where: MPMediaItemPropertyTitle, contains: term) where seen.insert(item.persistentID).inserted {
                items.append(item)
            }
        }
        let candidates = items.enumerated().map { index, item in
            MusicCatalogCandidate(id: String(index), kind: .song, title: item.title ?? "",
                                  artist: item.artist, popularityRank: 0)
        }
        var songRequest = request
        songRequest.kind = .song
        guard let best = MusicCatalogRanker.best(for: songRequest, among: candidates),
              let index = Int(best.id) else { return nil }
        let item = items[index]
        player.shuffleMode = .off
        player.setQueue(with: MPMediaItemCollection(items: [item]))
        player.play()
        return MusicLibraryMatch(kind: .song, title: item.title ?? request.title, artist: item.artist, trackCount: 1)
    }

    private func playArtist(_ name: String) -> MusicLibraryMatch? {
        let items = songs(where: MPMediaItemPropertyArtist, contains: name)
        guard !items.isEmpty else { return nil }
        player.setQueue(with: MPMediaItemCollection(items: items))
        player.shuffleMode = .songs
        player.play()
        return MusicLibraryMatch(kind: .artist, title: items.first?.artist ?? name, artist: nil,
                                 trackCount: items.count)
    }

    private func playAlbum(_ request: MusicPlayRequest) -> MusicLibraryMatch? {
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: request.title, forProperty: MPMediaItemPropertyAlbumTitle,
                                                          comparisonType: .contains))
        let collections = query.collections ?? []
        let candidates = collections.enumerated().map { index, collection in
            MusicCatalogCandidate(id: String(index), kind: .album,
                                  title: collection.representativeItem?.albumTitle ?? "",
                                  artist: collection.representativeItem?.albumArtist ?? collection.representativeItem?.artist,
                                  popularityRank: 0)
        }
        var albumRequest = request
        albumRequest.kind = .album
        guard let best = MusicCatalogRanker.best(for: albumRequest, among: candidates),
              let index = Int(best.id) else { return nil }
        let collection = collections[index]
        player.shuffleMode = .off
        player.setQueue(with: collection)
        player.play()
        return MusicLibraryMatch(kind: .album, title: best.title, artist: best.artist, trackCount: collection.count)
    }

    private func playPlaylist(_ request: MusicPlayRequest) -> MusicLibraryMatch? {
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: request.phrase, forProperty: MPMediaPlaylistPropertyName,
                                                          comparisonType: .contains))
        let playlists = (query.collections ?? []).compactMap { $0 as? MPMediaPlaylist }
        let candidates = playlists.enumerated().map { index, playlist in
            MusicCatalogCandidate(id: String(index), kind: .playlist, title: playlist.name ?? "",
                                  artist: nil, popularityRank: 0)
        }
        var playlistRequest = request
        playlistRequest.kind = .playlist
        playlistRequest.artist = nil
        guard let best = MusicCatalogRanker.best(for: playlistRequest, among: candidates),
              let index = Int(best.id) else { return nil }
        let playlist = playlists[index]
        player.setQueue(with: playlist)
        player.play()
        return MusicLibraryMatch(kind: .playlist, title: best.title, artist: nil, trackCount: playlist.count)
    }

    // MARK: - Helpers

    private func songs(where property: String, contains value: String) -> [MPMediaItem] {
        guard !value.isEmpty else { return [] }
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(value: value, forProperty: property, comparisonType: .contains))
        return query.items ?? []
    }
}
