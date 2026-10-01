import Foundation

/// Any Home Assistant `media_player.*` entity as a music provider (Plan GS P1).
///
/// The speaker may be a Sonos, a smart speaker, or a speaker Home Assistant plays a streaming
/// service on under its own account link. Avenkin only ever talks to the wearer's Home Assistant;
/// it never calls a streaming service itself.
///
/// Every call is gated on what the entity advertises in `supported_features`: a speaker that cannot
/// `play_media` is told so in one sentence rather than sent a call Home Assistant would reject.
@MainActor
final class HomeAssistantMusicProvider: MusicProvider {

    let id: MusicProviderID = .homeAssistant
    let capabilities: Set<MusicCapability> = [.transport, .volume, .nowPlaying, .playByName, .devices]

    private let client: HomeAssistantServiceCalling
    /// Steps "turn it up" moves the volume when a speaker only supports `volume_set`.
    static let volumeStep = 0.1

    init(client: HomeAssistantServiceCalling) {
        self.client = client
    }

    func nowPlaying(speaker: MusicSpeaker?) async -> NowPlayingSummary? {
        guard let speaker else { return nil }
        return try? await client.mediaPlayer(entityId: speaker.entityId)?.nowPlaying
    }

    func perform(_ command: MusicCommand, speaker: MusicSpeaker?) async -> MusicCommandResult {
        if case .devices = command {
            do {
                return .done(MusicPhraser.speakerList(try await client.mediaPlayers().map(\.speaker)))
            } catch {
                return .failed(Self.failureLine(error))
            }
        }
        guard let speaker else { return .failed(MusicPhraser.noSpeakers) }

        let state: HomeAssistantMediaPlayer
        do {
            guard let fetched = try await client.mediaPlayer(entityId: speaker.entityId) else {
                return .failed(MusicPhraser.noSpeakerNamed(speaker.name, available: []))
            }
            state = fetched
        } catch {
            return .failed(Self.failureLine(error))
        }
        let features = state.supportedFeatures

        do {
            switch command {
            case .play:
                try await call("media_play", speaker)
                return .done(MusicPhraser.sentToSpeaker(speaker, "Playing"))
            case .pause:
                try await call("media_pause", speaker)
                return .done(MusicPhraser.sentToSpeaker(speaker, "Paused"))
            case .toggle:
                try await call("media_play_pause", speaker)
                return .done(MusicPhraser.sentToSpeaker(speaker, state.isPlaying ? "Paused" : "Playing"))
            case .next:
                guard features.contains(.nextTrack) else { return .unsupported(MusicPhraser.speakerCannot(speaker, "skipping")) }
                try await call("media_next_track", speaker)
                return .done(MusicPhraser.sentToSpeaker(speaker, "Skipped"))
            case .previous:
                guard features.contains(.previousTrack) else { return .unsupported(MusicPhraser.speakerCannot(speaker, "going back")) }
                try await call("media_previous_track", speaker)
                return .done(MusicPhraser.sentToSpeaker(speaker, "Went back"))
            case .volumeUp, .volumeDown:
                let up = command == .volumeUp
                if features.contains(.volumeStep) {
                    try await call(up ? "volume_up" : "volume_down", speaker)
                } else if features.contains(.volumeSet), let current = state.volume {
                    let level = min(1, max(0, current + (up ? Self.volumeStep : -Self.volumeStep)))
                    try await call("volume_set", speaker, data: try HomeAssistantServiceData(["volume_level": .number(level)]))
                } else {
                    return .unsupported(MusicPhraser.speakerCannot(speaker, "volume control"))
                }
                return .done(MusicPhraser.sentToSpeaker(speaker, up ? "Turned it up" : "Turned it down"))
            case .volumeSet(let level):
                guard features.contains(.volumeSet) else { return .unsupported(MusicPhraser.speakerCannot(speaker, "setting the volume")) }
                let clamped = min(1, max(0, level))
                try await call("volume_set", speaker, data: try HomeAssistantServiceData(["volume_level": .number(clamped)]))
                return .done(MusicPhraser.sentToSpeaker(speaker, "Volume set to \(Int((clamped * 100).rounded())) percent"))
            case .nowPlaying:
                return .done(MusicPhraser.nowPlaying(state.nowPlaying))
            case .playByName(let request):
                guard features.contains(.playMedia) else {
                    return .unsupported(MusicPhraser.speakerCannot(speaker, "playing music by name"))
                }
                try await call("play_media", speaker, data: try Self.playMediaData(for: request))
                return .done("Asked \(speaker.name) to play \(request.phrase).")
            case .shuffle:
                return .unsupported(MusicPhraser.speakerCannot(speaker, "shuffle from Avenkin"))
            case .search, .addToLibrary:
                return .unsupported("Searching and adding to your library work with Apple Music on your phone.")
            case .devices:
                return .done(MusicPhraser.speakerList([speaker]))
            }
        } catch {
            return .failed(Self.failureLine(error))
        }
    }

    /// `play_media` service data: the phrase as the content id, typed as a playlist when the wearer
    /// said playlist and as music otherwise. What a content id means is up to the integration
    /// behind the speaker — many resolve names, favourites or playlists.
    static func playMediaData(for request: MusicPlayRequest) throws -> HomeAssistantServiceData {
        let type = request.kind == .playlist ? "playlist" : "music"
        return try HomeAssistantServiceData([
            "media_content_id": .string(request.phrase),
            "media_content_type": .string(type),
        ])
    }

    private func call(_ service: String, _ speaker: MusicSpeaker,
                      data: HomeAssistantServiceData = .empty) async throws {
        try await client.callService(domain: "media_player", service: service, entityId: speaker.entityId, data: data)
    }

    static func failureLine(_ error: Error) -> String {
        if error is MedicalEgressRefusal { return MedicalEgressRefusal.userMessage }
        return "Home Assistant didn't answer. Check that it's reachable from your phone."
    }
}
