import Foundation

/// A `media_player.*` entity's state, parsed out of `GET /api/states` (Plan GS P1). Pure.
struct HomeAssistantMediaPlayer: Equatable, Sendable {
    let entityId: String
    let name: String
    /// Home Assistant's state string: playing, paused, idle, on, off, standby, buffering, unavailable.
    let state: String
    let title: String?
    let artist: String?
    let album: String?
    /// 0...1.
    let volume: Double?
    let supportedFeatures: Features
    /// `app_name` — the app or service the player reports as its source.
    let appName: String?
    /// Seconds, from `media_position` / `media_duration`.
    let position: TimeInterval?
    let duration: TimeInterval?

    var isPlaying: Bool { state == "playing" }

    /// `MediaPlayerEntityFeature` bits, as Home Assistant publishes them in `supported_features`.
    struct Features: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let pause = Features(rawValue: 1)
        static let volumeSet = Features(rawValue: 4)
        static let previousTrack = Features(rawValue: 16)
        static let nextTrack = Features(rawValue: 32)
        static let playMedia = Features(rawValue: 512)
        static let volumeStep = Features(rawValue: 1024)
        static let play = Features(rawValue: 16384)
    }

    /// Parse one entry of the states array. Nil for anything that is not a media player.
    static func parse(_ json: [String: Any]) -> HomeAssistantMediaPlayer? {
        guard let entityId = json["entity_id"] as? String, entityId.hasPrefix("media_player.") else { return nil }
        let attributes = json["attributes"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String? {
            guard let value = attributes[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> Double? {
            (attributes[key] as? NSNumber)?.doubleValue
        }
        let object = entityId.dropFirst("media_player.".count).replacingOccurrences(of: "_", with: " ")
        return HomeAssistantMediaPlayer(
            entityId: entityId,
            name: text("friendly_name") ?? object.capitalized,
            state: (json["state"] as? String ?? "unknown").lowercased(),
            title: text("media_title"),
            artist: text("media_artist") ?? text("media_album_artist"),
            album: text("media_album_name"),
            volume: number("volume_level"),
            supportedFeatures: Features(rawValue: (attributes["supported_features"] as? NSNumber)?.intValue ?? 0),
            appName: text("app_name"),
            position: number("media_position"),
            duration: number("media_duration"))
    }

    /// Parse the whole `GET /api/states` array, keeping only media players, sorted by name.
    static func parseStates(_ json: [[String: Any]]) -> [HomeAssistantMediaPlayer] {
        json.compactMap(parse).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var speaker: MusicSpeaker { MusicSpeaker(entityId: entityId, name: name) }

    var nowPlaying: NowPlayingSummary {
        let mapped: NowPlayingSummary.State
        switch state {
        case "playing", "buffering": mapped = .playing
        case "paused": mapped = .paused
        default: mapped = .stopped
        }
        return NowPlayingSummary(title: title, artist: artist, album: album, releaseYear: nil, state: mapped,
                                 elapsed: position, duration: duration, provider: .homeAssistant,
                                 speakerName: name, sourceApp: appName, catalogID: nil)
    }
}
