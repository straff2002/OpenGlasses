import Foundation

// Plan GS — the music provider layer's value types. Pure: nothing here touches MediaPlayer,
// MusicKit or the network, so the routing, ranking and phrasing built on them test headlessly.

/// Where music can be played or controlled from.
enum MusicProviderID: String, CaseIterable, Sendable, Equatable {
    /// The Music app on the phone: the wearer's library through MediaPlayer, and the Apple Music
    /// catalogue through MusicKit when they subscribe.
    case appleMusic
    /// A `media_player.*` entity on the wearer's Home Assistant server — a Sonos, a smart speaker,
    /// or a speaker Home Assistant drives under its own arrangement with a streaming service.
    case homeAssistant

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .homeAssistant: return "Home Assistant speaker"
        }
    }
}

/// What kind of thing a play-by-name request is after. `any` lets the ranker choose.
enum MusicItemKind: String, CaseIterable, Sendable, Equatable {
    case song, album, artist, playlist, station, any

    /// How the kind reads in a spoken answer ("the album", "the playlist").
    var spokenNoun: String? {
        switch self {
        case .song: return "song"
        case .album: return "album"
        case .artist: return "artist"
        case .playlist: return "playlist"
        case .station: return "station"
        case .any: return nil
        }
    }
}

/// A parsed play-by-name request.
///
/// Two readings are carried because " by " is ambiguous: "Rumours by Fleetwood Mac" names an
/// artist, "Stand by Me" does not. `title`/`artist` is the split reading; `phrase` is the whole
/// thing. The ranker scores a candidate against both and keeps the better.
struct MusicPlayRequest: Equatable, Sendable {
    var kind: MusicItemKind
    /// The whole cleaned phrase, kind words removed ("stand by me", "rumours by fleetwood mac").
    var phrase: String
    /// The title half of a "<title> by <artist>" reading, or the phrase when there is no " by ".
    var title: String
    var artist: String?
    /// The wearer said "shuffle" or asked for an artist, where a shuffled queue is the useful one.
    var shuffle: Bool = false

    /// The term sent to a catalogue or library search.
    var searchTerm: String { phrase }
}

/// A command for a provider. Mirrors the `music_control` actions one to one.
enum MusicCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case next
    case previous
    case shuffle
    case volumeUp
    case volumeDown
    /// 0...1.
    case volumeSet(Double)
    case nowPlaying
    case search(String)
    case playByName(MusicPlayRequest)
    /// Add the named item, or what is playing when nil.
    case addToLibrary(MusicPlayRequest?)
    case devices

    /// Commands that only read. The rest act on the wearer's player, so the temple-tap trigger
    /// must stand down before they run.
    var isReadOnly: Bool {
        switch self {
        case .nowPlaying, .search, .devices, .addToLibrary: return true
        default: return false
        }
    }

    /// Transport commands follow whichever provider is already playing.
    var isTransport: Bool {
        switch self {
        case .play, .pause, .toggle, .next, .previous, .volumeUp, .volumeDown, .volumeSet, .nowPlaying:
            return true
        default:
            return false
        }
    }

    /// Catalogue and library operations exist only on the phone.
    var isAppleMusicOnly: Bool {
        switch self {
        case .search, .addToLibrary: return true
        default: return false
        }
    }
}

/// What a provider can do. The tool uses it to answer honestly instead of calling a service the
/// target does not advertise.
enum MusicCapability: String, CaseIterable, Sendable {
    case transport, volume, nowPlaying, playByName, search, addToLibrary, devices
}

/// A provider's answer: the sentence to speak and whether it did the thing.
struct MusicCommandResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case done
        /// The provider cannot do this (no API, not advertised).
        case unsupported
        /// Nothing matched, or the service refused.
        case failed
        /// The wearer needs to answer a question (which speaker?).
        case needsInput
    }

    let spoken: String
    let outcome: Outcome

    static func done(_ spoken: String) -> MusicCommandResult { .init(spoken: spoken, outcome: .done) }
    static func unsupported(_ spoken: String) -> MusicCommandResult { .init(spoken: spoken, outcome: .unsupported) }
    static func failed(_ spoken: String) -> MusicCommandResult { .init(spoken: spoken, outcome: .failed) }
}

/// A Home Assistant media player the wearer has let Avenkin use.
struct MusicSpeaker: Equatable, Sendable, Identifiable {
    let entityId: String
    let name: String
    var id: String { entityId }
}

/// What is playing, from whichever provider can see it.
struct NowPlayingSummary: Equatable, Sendable {
    enum State: Equatable, Sendable { case playing, paused, stopped }

    var title: String?
    var artist: String?
    var album: String?
    var releaseYear: Int?
    var state: State
    /// Seconds into the track, when known.
    var elapsed: TimeInterval?
    /// Track length in seconds, when known.
    var duration: TimeInterval?
    var provider: MusicProviderID
    /// The Home Assistant speaker's name, for a speaker.
    var speakerName: String?
    /// The app a speaker reports as its source (Home Assistant's `app_name`), e.g. a streaming
    /// service Home Assistant itself is connected to.
    var sourceApp: String?
    /// The Apple Music catalogue id of the playing song, when the phone knows it — what "add this
    /// to my library" adds.
    var catalogID: String?

    var hasTrack: Bool { title != nil || artist != nil }
}

/// Access to Apple Music as MusicKit reports it, without importing MusicKit into the pure core.
enum MusicAccessStatus: String, Sendable, Equatable {
    case notDetermined, denied, restricted, authorized
}

/// One catalogue search hit, flattened out of MusicKit's typed collections so ranking is pure.
struct MusicCatalogCandidate: Equatable, Sendable {
    let id: String
    let kind: MusicItemKind
    let title: String
    /// Artist for songs and albums, curator for playlists, nil for artists and stations.
    let artist: String?
    /// Position in the service's own relevance order within its kind (0 = first).
    let popularityRank: Int
}

/// A match from the wearer's own library.
struct MusicLibraryMatch: Equatable, Sendable {
    let kind: MusicItemKind
    let title: String
    let artist: String?
    /// How many tracks the selection queues.
    let trackCount: Int
}

/// Failures a catalogue call can report, mapped out of MusicKit's error types.
enum MusicCatalogFailure: Error, Equatable, Sendable {
    case notAuthorized
    case notSubscribed
    case notFound
    case alreadyInLibrary
    case unavailable
}
