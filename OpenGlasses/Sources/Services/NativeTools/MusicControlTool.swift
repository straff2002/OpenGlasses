import Foundation
@preconcurrency import MediaPlayer

/// Controls music playback on the device — play, pause, skip, search, and play by name.
struct MusicControlTool: NativeTool {
    let name = "music_control"
    let description = "Control music: play, pause, next, previous, now_playing, search (find songs/artists/albums in library), play_song (play a specific song by name), play_artist (play songs by an artist), shuffle."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'play', 'pause', 'toggle', 'next', 'previous', 'now_playing', 'search', 'play_song', 'play_artist', 'shuffle'",
            ],
            "query": [
                "type": "string",
                "description": "Search query for 'search', 'play_song', or 'play_artist' actions (song name, artist name, or album)",
            ],
        ],
        "required": ["action"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action provided. Use: play, pause, toggle, next, previous, or now_playing."
        }

        // Search and play-by-name need async work, handle separately
        switch action.lowercased() {
        case "search":
            let query = args["query"] as? String ?? ""
            guard !query.isEmpty else { return "What should I search for?" }
            return await searchLibrary(query: query)

        case "play_song":
            let query = args["query"] as? String ?? ""
            guard !query.isEmpty else { return "What song should I play?" }
            return await playSong(query: query)

        case "play_artist":
            let query = args["query"] as? String ?? ""
            guard !query.isEmpty else { return "Which artist?" }
            return await playArtist(query: query)

        default:
            break
        }

        // Simple playback controls — all on MainActor
        return await MainActor.run {
            let player = MPMusicPlayerController.systemMusicPlayer

            switch action.lowercased() {
            case "play":
                player.play()
                return nowPlayingDescription(prefix: "Playing", player: player)

            case "pause", "stop":
                player.pause()
                return "Music paused."

            case "toggle", "play_pause":
                if player.playbackState == .playing {
                    player.pause()
                    return "Music paused."
                } else {
                    player.play()
                    return nowPlayingDescription(prefix: "Playing", player: player)
                }

            case "next", "skip":
                player.skipToNextItem()
                return nowPlayingDescription(prefix: "Skipped to", player: player)

            case "previous", "prev", "back":
                player.skipToPreviousItem()
                return nowPlayingDescription(prefix: "Going back to", player: player)

            case "now_playing", "current", "what_is_playing":
                return nowPlayingDescription(prefix: "Now playing", player: player)

            case "shuffle":
                player.shuffleMode = .songs
                player.play()
                return "Shuffling your library."

            default:
                return "Unknown action '\(action)'. Use: play, pause, toggle, next, previous, now_playing, search, play_song, play_artist, or shuffle."
            }
        }
    }

    // MARK: - Search & Play

    private func searchLibrary(query: String) async -> String {
        return await MainActor.run {
            let predicate = MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains)
            let songQuery = MPMediaQuery.songs()
            songQuery.addFilterPredicate(predicate)

            let songs = songQuery.items ?? []

            // Also search by artist
            let artistPredicate = MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains)
            let artistQuery = MPMediaQuery.songs()
            artistQuery.addFilterPredicate(artistPredicate)
            let artistSongs = artistQuery.items ?? []

            let allResults = Array(Set(songs + artistSongs)).prefix(5)

            if allResults.isEmpty {
                return "No songs found matching '\(query)' in your library. Try a different search or open Apple Music/Spotify directly."
            }

            let list = allResults.map { item in
                let title = item.title ?? "Unknown"
                let artist = item.artist ?? "Unknown"
                return "'\(title)' by \(artist)"
            }.joined(separator: ". ")

            return "Found \(allResults.count) songs: \(list). Say 'play song \(allResults.first?.title ?? query)' to play one."
        }
    }

    private func playSong(query: String) async -> String {
        return await MainActor.run {
            let predicate = MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains)
            let songQuery = MPMediaQuery.songs()
            songQuery.addFilterPredicate(predicate)

            guard let item = songQuery.items?.first else {
                return "Couldn't find '\(query)' in your library."
            }

            let player = MPMusicPlayerController.systemMusicPlayer
            let collection = MPMediaItemCollection(items: [item])
            player.setQueue(with: collection)
            player.play()
            return nowPlayingDescription(prefix: "Playing", player: player)
        }
    }

    private func playArtist(query: String) async -> String {
        return await MainActor.run {
            let predicate = MPMediaPropertyPredicate(value: query, forProperty: MPMediaItemPropertyArtist, comparisonType: .contains)
            let artistQuery = MPMediaQuery.songs()
            artistQuery.addFilterPredicate(predicate)

            guard let items = artistQuery.items, !items.isEmpty else {
                return "No songs by '\(query)' in your library."
            }

            let player = MPMusicPlayerController.systemMusicPlayer
            let collection = MPMediaItemCollection(items: items)
            player.setQueue(with: collection)
            player.shuffleMode = .songs
            player.play()
            return "Playing \(items.count) songs by \(items.first?.artist ?? query). \(nowPlayingDescription(prefix: "Starting with", player: player))"
        }
    }

    // MARK: - Info

    private func nowPlayingDescription(prefix: String, player: MPMusicPlayerController) -> String {
        guard let item = player.nowPlayingItem else {
            return "\(prefix): No track currently loaded. Try opening Music or Spotify first."
        }

        let title = item.title ?? "Unknown Track"
        let artist = item.artist ?? "Unknown Artist"
        var info = "\(prefix): '\(title)' by \(artist)"

        if let album = item.albumTitle, !album.isEmpty {
            info += " from '\(album)'"
        }

        return info + "."
    }
}
