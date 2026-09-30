import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Controls music — the Apple Music catalogue and library on the phone, or a Home Assistant
/// speaker (Plan GS).
///
/// The tool is a thin shell: it turns arguments into a `MusicCommand` and a target, gathers the
/// routing context, lets `MusicCommandRouter` pick the provider, and speaks the provider's answer.
/// Everything it depends on arrives through `MusicControlEnvironment`, so tests drive it with fakes.
struct MusicControlTool: NativeTool {
    let name = "music_control"
    let description = """
        Play and control music. Apple Music on the phone is the default; the wearer can make a Home Assistant \
        speaker the default in Settings. Play-by-name searches the whole Apple Music catalogue when the wearer \
        subscribes to Apple Music, and only their own library otherwise — the tool says which. \
        Actions: play (with 'query' to play something by name), pause, toggle, next, previous, shuffle, \
        now_playing, search, play_song, play_artist, play_album, play_playlist, play_station, \
        add_to_library (the playing song, or 'query'), volume_up, volume_down, volume_set ('level' 0-100, speakers only), \
        devices (list speakers). 'device' names a Home Assistant speaker ('kitchen'). \
        It cannot control Spotify or other apps; never promise that — pass provider 'spotify' and it explains.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "play, pause, toggle, next, previous, shuffle, now_playing, search, play_song, play_artist, play_album, play_playlist, play_station, add_to_library, volume_up, volume_down, volume_set, devices",
            ],
            "query": [
                "type": "string",
                "description": "What to play, search for or add: a song, artist, album, playlist or station name, optionally 'by <artist>'",
            ],
            "device": [
                "type": "string",
                "description": "A Home Assistant speaker's name, when the wearer names one ('kitchen', 'living room')",
            ],
            "provider": [
                "type": "string",
                "description": "Only when the wearer names a service: 'apple_music', 'home_assistant', or the service they said (e.g. 'spotify')",
            ],
            "level": [
                "type": "number",
                "description": "Volume for volume_set, 0-100",
            ],
        ],
        "required": ["action"],
    ]

    /// Builds the per-call environment. Tests inject fakes.
    var makeEnvironment: @MainActor () -> MusicControlEnvironment = { MusicControlEnvironment.live() }

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action provided. Use: play, pause, toggle, next, previous, or now_playing."
        }
        return await Self.run(MusicToolRequest.parse(action: action, args: args), makeEnvironment: makeEnvironment)
    }

    @MainActor
    private static func run(_ request: MusicToolRequest,
                            makeEnvironment: @MainActor () -> MusicControlEnvironment) async -> String {
        await makeEnvironment().run(request)
    }
}

// MARK: - Arguments

/// A `music_control` call, parsed. Pure.
struct MusicToolRequest: Equatable {
    enum Parsed: Equatable {
        case command(MusicCommand)
        /// Say this and stop (missing query, unknown action).
        case reply(String)
    }

    var parsed: Parsed
    var target: MusicRequestParser.Target
    /// "like"/"love": the answer explains that Apple Music has no love for apps.
    var isLike = false

    static func parse(action rawAction: String, args: [String: Any]) -> MusicToolRequest {
        let action = rawAction.lowercased()
        let rawQuery = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // A trailing "on the kitchen speaker" / "on Spotify" inside the query is a target.
        var query = ""
        var target = MusicRequestParser.Target()
        if !rawQuery.isEmpty {
            let extracted = MusicRequestParser.extractTarget(from: rawQuery)
            query = extracted.rest
            target = extracted.target
        }
        if let service = MusicRequestParser.service(named: args["provider"] as? String) {
            target.service = service
        }
        if let device = (args["device"] as? String)?.trimmingCharacters(in: .whitespaces), !device.isEmpty {
            let named = MusicRequestParser.deviceTarget(device)
            if let service = named.service { target.service = service }
            if let speaker = named.device { target.device = speaker }
        }

        func byName(_ kind: MusicItemKind, missing: String, shuffle: Bool = false) -> Parsed {
            guard !query.isEmpty else {
                // "play spotify" leaves no query — still a play, so the router can answer.
                return target.service != nil || target.device != nil ? .command(.play) : .reply(missing)
            }
            var request = MusicRequestParser.request(from: query, kind: kind)
            if shuffle { request.shuffle = true }
            return .command(.playByName(request))
        }

        let parsed: Parsed
        var isLike = false
        switch action {
        case "play", "resume":
            parsed = query.isEmpty ? .command(.play) : byName(.any, missing: "")
        case "pause", "stop":
            parsed = .command(.pause)
        case "toggle", "play_pause":
            parsed = .command(.toggle)
        case "next", "skip":
            parsed = .command(.next)
        case "previous", "prev", "back":
            parsed = .command(.previous)
        case "shuffle":
            parsed = query.isEmpty ? .command(.shuffle) : byName(.any, missing: "", shuffle: true)
        case "now_playing", "current", "what_is_playing":
            parsed = .command(.nowPlaying)
        case "search":
            parsed = query.isEmpty ? .reply("What should I search for?") : .command(.search(query))
        case "play_song":
            parsed = byName(.song, missing: "What song should I play?")
        case "play_artist":
            parsed = byName(.artist, missing: "Which artist?")
        case "play_album":
            parsed = byName(.album, missing: "Which album?")
        case "play_playlist":
            parsed = byName(.playlist, missing: "Which playlist?")
        case "play_station", "play_radio":
            parsed = byName(.station, missing: "Which station?")
        case "add_to_library", "save", "like", "love":
            isLike = action == "like" || action == "love"
            parsed = .command(.addToLibrary(query.isEmpty ? nil : MusicRequestParser.request(from: query)))
        case "volume_up", "louder":
            parsed = .command(.volumeUp)
        case "volume_down", "quieter":
            parsed = .command(.volumeDown)
        case "volume_set", "set_volume", "volume":
            if let level = Self.level(args["level"]) {
                parsed = .command(.volumeSet(level))
            } else {
                parsed = .reply("What volume, from 0 to 100?")
            }
        case "devices", "speakers", "list_devices":
            parsed = .command(.devices)
        default:
            parsed = .reply("Unknown action '\(rawAction)'. Use: play, pause, toggle, next, previous, now_playing, search, play_song, play_artist, play_album, play_playlist, play_station, add_to_library, shuffle, volume_up, volume_down, volume_set, or devices.")
        }
        return MusicToolRequest(parsed: parsed, target: target, isLike: isLike)
    }

    /// 0...100 (or 0...1) → 0...1.
    static func level(_ raw: Any?) -> Double? {
        let value: Double?
        if let number = raw as? NSNumber { value = number.doubleValue }
        else if let text = raw as? String { value = Double(text.replacingOccurrences(of: "%", with: "")) }
        else { value = nil }
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value > 1 ? min(value, 100) / 100 : value
    }
}

// MARK: - Environment

/// Everything a `music_control` call reads or drives. `live()` wires production; tests build one
/// from fakes.
@MainActor
struct MusicControlEnvironment {
    var appleMusic: MusicProvider
    var homeAssistant: MusicProvider?
    /// Lists speakers and which are playing. Nil when Home Assistant is unusable.
    var homeAssistantClient: HomeAssistantServiceCalling?
    /// Why Home Assistant is unusable, when it is.
    var homeAssistantUnavailableLine: String?
    var defaultProvider: MusicProviderID
    var defaultSpeakerEntityId: String?
    var hiddenSpeakers: Set<String>
    var askWhenUnsure: Bool
    var appleMusicPlaying: () -> Bool
    /// Tells the temple-tap trigger to drop its Now Playing claim before the wearer's player acts.
    var postUserPlaybackRequested: () -> Void

    static func live() -> MusicControlEnvironment {
        let library = MediaPlayerLibrary()
        let apple = AppleMusicProvider(
            library: library,
            catalog: MusicKitCatalog(),
            catalogueAllowed: { !MedicalEgressGuard.currentMode().isEnforcing },
            canPromptForAccess: {
                #if canImport(UIKit)
                UIApplication.shared.applicationState == .active
                #else
                false
                #endif
            })
        let client = HomeAssistantRESTClient()
        let unavailable: String?
        if !client.isConfigured {
            unavailable = MusicPhraser.speakersNeedHomeAssistant
        } else if !MedicalEgressGuard.allows(.homeAssistantCommand) {
            unavailable = MedicalEgressRefusal.userMessage
        } else {
            unavailable = nil
        }
        let speakerDefault = Config.musicDefaultSpeaker
        return MusicControlEnvironment(
            appleMusic: apple,
            homeAssistant: unavailable == nil ? HomeAssistantMusicProvider(client: client) : nil,
            homeAssistantClient: unavailable == nil ? client : nil,
            homeAssistantUnavailableLine: unavailable,
            defaultProvider: Config.musicDefaultProvider,
            defaultSpeakerEntityId: speakerDefault.isEmpty ? nil : speakerDefault,
            hiddenSpeakers: Set(Config.musicHiddenSpeakers),
            askWhenUnsure: Config.musicAskWhichSpeaker,
            appleMusicPlaying: { library.isPlaying },
            postUserPlaybackRequested: {
                NotificationCenter.default.post(name: MediaTriggerService.userPlaybackRequested, object: nil)
            })
    }

    // MARK: - Running a call

    func run(_ request: MusicToolRequest) async -> String {
        await execute(request).spoken
    }

    /// The outcome as well as the words — a temple tap speaks only answers the wearer needs.
    func execute(_ request: MusicToolRequest) async -> MusicCommandResult {
        let command: MusicCommand
        switch request.parsed {
        case .reply(let line): return MusicCommandResult(spoken: line, outcome: .needsInput)
        case .command(let parsed): command = parsed
        }

        var context = MusicCommandRouter.Context(
            defaultProvider: defaultProvider,
            homeAssistantUsable: homeAssistantClient != nil && homeAssistant != nil,
            homeAssistantUnavailableLine: homeAssistantUnavailableLine,
            speakers: [],
            defaultSpeakerEntityId: defaultSpeakerEntityId,
            askWhenUnsure: askWhenUnsure,
            appleMusicPlaying: appleMusicPlaying(),
            playingSpeakerEntityIds: [])

        if let client = homeAssistantClient, Self.needsSpeakers(command, target: request.target, context: context) {
            do {
                let players = try await client.mediaPlayers().filter { !hiddenSpeakers.contains($0.entityId) }
                context.speakers = players.map(\.speaker)
                context.playingSpeakerEntityIds = players.filter(\.isPlaying).map(\.entityId)
            } catch {
                context.homeAssistantUsable = false
                context.homeAssistantUnavailableLine = HomeAssistantMusicProvider.failureLine(error)
            }
        }

        if command == .devices {
            guard context.homeAssistantUsable else {
                return .failed(context.homeAssistantUnavailableLine ?? MusicPhraser.speakersNeedHomeAssistant)
            }
            return .done(MusicPhraser.speakerList(context.speakers))
        }

        let result: MusicCommandResult
        switch MusicCommandRouter.route(command, target: request.target, context: context) {
        case .refuse(let line):
            return .unsupported(line)
        case .askSpeaker(let speakers):
            return MusicCommandResult(spoken: MusicPhraser.askWhichSpeaker(speakers), outcome: .needsInput)
        case .appleMusic:
            // Commands are for the wearer's own player: the temple-tap trigger drops its claim
            // first so it never races their playback for Now Playing.
            if !command.isReadOnly { postUserPlaybackRequested() }
            result = await appleMusic.perform(command, speaker: nil)
        case .homeAssistant(let speaker):
            // A speaker plays in the room, not on the phone: the phone's Now Playing is untouched.
            guard let homeAssistant else { return .failed(MusicPhraser.speakersNeedHomeAssistant) }
            result = await homeAssistant.perform(command, speaker: speaker)
        }

        if request.isLike, result.outcome == .done, result.spoken.hasPrefix("Added") {
            return .done(MusicPhraser.likeIsAddToLibrary)
        }
        return result
    }

    /// Whether routing needs the speaker list — a network call to Home Assistant, skipped when the
    /// answer cannot change the route.
    static func needsSpeakers(_ command: MusicCommand, target: MusicRequestParser.Target,
                              context: MusicCommandRouter.Context) -> Bool {
        guard context.homeAssistantUsable else { return false }
        if target.device != nil || target.service == .homeAssistant { return true }
        if command.isAppleMusicOnly { return false }
        if command == .devices { return true }
        if case .unsupported? = target.service { return context.defaultProvider == .homeAssistant }
        if target.service == .appleMusic { return false }
        if command.isTransport {
            return !(context.appleMusicPlaying && context.defaultProvider == .appleMusic)
        }
        return context.defaultProvider == .homeAssistant
    }
}
