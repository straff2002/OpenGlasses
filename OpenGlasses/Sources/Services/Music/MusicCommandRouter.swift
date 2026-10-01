import Foundation

/// Decides which provider a music command goes to (Plan GS P0). Pure.
///
/// Rules, in order:
/// 1. A named speaker wins — "on the kitchen speaker" goes to that Home Assistant media player.
/// 2. A named service with no route ("on Spotify") gets one honest sentence, unless the wearer's
///    default is a Home Assistant speaker, which may well be the thing playing that service.
/// 3. Catalogue and library operations (search, add to library) are Apple Music's alone.
/// 4. Transport commands follow the provider that is already playing, else the default.
/// 5. Play-by-name goes to the default provider.
///
/// A Home Assistant route that is unusable (not set up, or blocked by Medical Local Only) is never
/// a dead end when the wearer did not ask for it: the command falls back to Apple Music.
enum MusicCommandRouter {

    struct Context: Equatable {
        var defaultProvider: MusicProviderID = .appleMusic
        /// Home Assistant is configured and the Medical Local Only rule lets it be reached.
        var homeAssistantUsable: Bool = false
        /// Why Home Assistant is unusable, when it is — spoken if the wearer asked for a speaker.
        var homeAssistantUnavailableLine: String? = nil
        /// The speakers the wearer has left available, in their preferred order.
        var speakers: [MusicSpeaker] = []
        var defaultSpeakerEntityId: String? = nil
        /// Ask "which speaker?" rather than guess when there is more than one and no default.
        var askWhenUnsure: Bool = true
        /// The phone's Music app is playing.
        var appleMusicPlaying: Bool = false
        /// Speakers Home Assistant reports as playing.
        var playingSpeakerEntityIds: [String] = []
    }

    enum Route: Equatable {
        case appleMusic
        case homeAssistant(MusicSpeaker)
        /// Say this and do nothing.
        case refuse(String)
        /// Ask which speaker, naming the choices.
        case askSpeaker([MusicSpeaker])
    }

    static func route(_ command: MusicCommand, target: MusicRequestParser.Target,
                      context: Context) -> Route {
        // 1. A named speaker.
        if let device = target.device, !device.isEmpty {
            guard context.homeAssistantUsable else {
                return .refuse(context.homeAssistantUnavailableLine ?? MusicPhraser.speakersNeedHomeAssistant)
            }
            guard let speaker = matchSpeaker(device, in: context.speakers) else {
                return .refuse(MusicPhraser.noSpeakerNamed(device, available: context.speakers))
            }
            if command.isAppleMusicOnly { return .appleMusic }
            return .homeAssistant(speaker)
        }

        // 2. A named service.
        switch target.service {
        case .unsupported(let service)?:
            if context.defaultProvider == .homeAssistant, context.homeAssistantUsable,
               !command.isAppleMusicOnly, let speaker = unambiguousSpeaker(context) {
                return .homeAssistant(speaker)
            }
            return .refuse(MusicPhraser.cannotControl(service))
        case .appleMusic?:
            return .appleMusic
        case .homeAssistant?:
            guard context.homeAssistantUsable else {
                return .refuse(context.homeAssistantUnavailableLine ?? MusicPhraser.speakersNeedHomeAssistant)
            }
            if command.isAppleMusicOnly { return .appleMusic }
            return resolveSpeaker(context)
        case nil:
            break
        }

        // 3. The phone's own catalogue and library.
        if command.isAppleMusicOnly { return .appleMusic }

        // `devices` lists speakers; it is answered by the tool, but routing it keeps one door.
        if command == .devices {
            guard context.homeAssistantUsable else {
                return .refuse(context.homeAssistantUnavailableLine ?? MusicPhraser.speakersNeedHomeAssistant)
            }
            return context.speakers.first.map { .homeAssistant($0) } ?? .refuse(MusicPhraser.noSpeakers)
        }

        // 4. Transport follows what is playing.
        if command.isTransport {
            let playingSpeakers = context.homeAssistantUsable
                ? context.speakers.filter { context.playingSpeakerEntityIds.contains($0.entityId) }
                : []
            let default_ = context.homeAssistantUsable ? context.defaultProvider : .appleMusic
            switch (context.appleMusicPlaying, playingSpeakers.isEmpty) {
            case (true, true):
                return .appleMusic
            case (false, false):
                return .homeAssistant(preferred(playingSpeakers, context))
            case (true, false):
                // Both are playing: the default provider breaks the tie.
                return default_ == .appleMusic ? .appleMusic : .homeAssistant(preferred(playingSpeakers, context))
            case (false, true):
                // Nothing is playing anywhere. "What's playing?" must not turn into "which
                // speaker?": ask the default speaker only when there is no doubt which one, and
                // otherwise let the phone give its honest "nothing is playing" answer.
                if command == .nowPlaying {
                    guard context.defaultProvider == .homeAssistant, context.homeAssistantUsable,
                          let speaker = unambiguousSpeaker(context) else { return .appleMusic }
                    return .homeAssistant(speaker)
                }
            }
        }

        // 5. The default provider.
        guard context.defaultProvider == .homeAssistant, context.homeAssistantUsable else {
            return .appleMusic
        }
        return resolveSpeaker(context)
    }

    // MARK: - Speakers

    /// The speaker a Home Assistant route uses when none was named.
    static func resolveSpeaker(_ context: Context) -> Route {
        guard !context.speakers.isEmpty else { return .refuse(MusicPhraser.noSpeakers) }
        if let speaker = unambiguousSpeaker(context) { return .homeAssistant(speaker) }
        return context.askWhenUnsure ? .askSpeaker(context.speakers) : .homeAssistant(context.speakers[0])
    }

    /// Default speaker, else the one playing, else the only one.
    private static func unambiguousSpeaker(_ context: Context) -> MusicSpeaker? {
        if let id = context.defaultSpeakerEntityId, let speaker = context.speakers.first(where: { $0.entityId == id }) {
            return speaker
        }
        let playing = context.speakers.filter { context.playingSpeakerEntityIds.contains($0.entityId) }
        if playing.count == 1 { return playing[0] }
        if context.speakers.count == 1 { return context.speakers[0] }
        return nil
    }

    private static func preferred(_ playing: [MusicSpeaker], _ context: Context) -> MusicSpeaker {
        if let id = context.defaultSpeakerEntityId, let speaker = playing.first(where: { $0.entityId == id }) {
            return speaker
        }
        return playing[0]
    }

    /// Match a spoken speaker name against friendly names and entity ids. Exact beats contains.
    static func matchSpeaker(_ spoken: String, in speakers: [MusicSpeaker]) -> MusicSpeaker? {
        let want = MusicRequestParser.normalizedWords(spoken)
        guard !want.isEmpty else { return nil }
        func names(_ speaker: MusicSpeaker) -> [String] {
            let object = speaker.entityId.split(separator: ".").last.map(String.init) ?? speaker.entityId
            return [MusicRequestParser.normalizedWords(speaker.name),
                    MusicRequestParser.normalizedWords(object.replacingOccurrences(of: "_", with: " "))]
        }
        if let exact = speakers.first(where: { names($0).contains(want) }) { return exact }
        return speakers.first { speaker in
            names(speaker).contains { (" " + $0 + " ").contains(" " + want + " ") }
        }
    }
}
