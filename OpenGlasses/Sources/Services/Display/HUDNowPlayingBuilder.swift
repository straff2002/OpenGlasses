import Foundation

/// What the Now Playing card shows (Plan KX §6): the track and whether it is playing.
struct HUDNowPlaying: Equatable {
    var title: String?
    var artist: String?
    var isPlaying: Bool

    /// From the Music app's system player (`MediaPlayerLibrary.nowPlaying()`); nil when nothing
    /// is loaded.
    init?(_ summary: NowPlayingSummary?) {
        guard let summary else { return nil }
        self.init(title: summary.title, artist: summary.artist, isPlaying: summary.state == .playing)
    }

    init(title: String?, artist: String?, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

/// What a press on the Now Playing card does.
enum HUDMediaAction: Equatable {
    case previous, toggle, next, close
}

/// Plan KX §6: the Now Playing card, reached from the launcher's Menu (Today › Menu › Now
/// Playing). Pure.
///
/// The track's title (with the music mark) and artist, then **‹‹** · **Pause** / **Play** (primary,
/// focused) · **››** · **Close**. With nothing loaded it is **Play** · **Close**.
///
/// **No Vol − / Vol +.** The plan asked for them because the band's volume twist does not work
/// during a DAT session (iOS #330), but iOS gives an app no supported way to set the system volume:
/// `MPMusicPlayerController.volume` has been deprecated since iOS 7 and does nothing, and
/// `MPVolumeView`'s slider is a control the wearer drags, not an API (driving it from code is the
/// private-API pattern App Review rejects). Volume stays on the glasses' touchpad and the phone's
/// buttons, and four buttons stay well inside the band's focus reach.
///
/// **What it drives.** The Music app's player only (`MPMusicPlayerController.systemMusicPlayer`,
/// through `MediaPlayerLibrary`) — the same transport `music_control` uses. Another app's audio
/// cannot be read or driven by a third-party app on iOS.
enum HUDNowPlayingBuilder {
    enum ItemID {
        static let previous = "kx.media.previous"
        static let toggle = "kx.media.toggle"
        static let next = "kx.media.next"
        static let close = "kx.media.close"
    }

    static var title: String {
        String(localized: "Now Playing", comment: "Glasses: heading of the Now Playing card, and its launcher item.")
    }

    static func screen(_ playing: HUDNowPlaying?, onAction: @escaping (HUDMediaAction) -> Void) -> HUDScreen {
        var lines: [HUDLine] = []
        let trackTitle = playing?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = playing?.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trackTitle.isEmpty && artist.isEmpty {
            lines.append(HUDLine(String(localized: "Nothing playing", comment: "Glasses: the Now Playing card with nothing loaded."),
                                 icon: .music, emphasis: .secondary))
        } else {
            if !trackTitle.isEmpty { lines.append(HUDLine(trackTitle, icon: .music)) }
            if !artist.isEmpty { lines.append(HUDLine(artist, icon: trackTitle.isEmpty ? .music : .none, emphasis: .secondary)) }
        }
        let isPlaying = playing?.isPlaying ?? false
        let toggle = HUDItem(id: ItemID.toggle,
                             label: isPlaying
                                ? String(localized: "Pause", comment: "Glasses: pauses the music.")
                                : String(localized: "Play", comment: "Glasses: plays the music."),
                             style: .primary) { onAction(.toggle) }
        let close = HUDItem(id: ItemID.close, label: String(localized: "Close", comment: "Glasses: closes a card."),
                            style: .outline) { onAction(.close) }
        var items: [HUDItem]
        if playing == nil {
            items = [toggle, close]
        } else {
            items = [
                HUDItem(id: ItemID.previous, label: "‹‹", style: .secondary) { onAction(.previous) },
                toggle,
                HUDItem(id: ItemID.next, label: "››", style: .secondary) { onAction(.next) },
                close,
            ]
        }
        return HUDScreen(title: title, lines: lines, items: items, focusItemID: ItemID.toggle)
    }

    /// Whether `screen` is the Now Playing card (so a redraw after a press lands only on it).
    static func isNowPlaying(_ screen: HUDScreen?) -> Bool {
        screen?.items.contains { $0.id == ItemID.toggle } ?? false
    }
}
