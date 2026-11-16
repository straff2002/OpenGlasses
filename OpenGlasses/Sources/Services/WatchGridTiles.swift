import Foundation

/// The phone's side of the watch's tile grid: which tiles the wrist gets, and what a tap on one
/// runs. Pure, so the order and the wrist's rules are provable without a paired watch.
///
/// The tiles are the phone grid's own action tiles in the order the phone draws them, so the first
/// rows on the watch are the first rows on the phone. The grid's controls (the model picker, Type,
/// Preview…) stay on the phone: they work the phone's screen, and the watch has its own Listen,
/// Photo, Video and Sleep.
///
/// A tap runs what the tile runs on the phone, with the wrist's one difference (as for every watch
/// photo command): it never opens the phone's camera. A photo tile uses the glasses, and a tile
/// that would open the phone's camera first is refused with a line saying so.
enum WatchGridTiles {
    /// The wrist's tiles, from the phone's grid as drawn.
    static func tiles(slots: [DockSlot], photoBlocked: Bool) -> [WatchGridWire.Tile] {
        let entries: [HomeGridEntry] = slots.compactMap { slot in
            guard case .action(let entry) = slot, runsFromWrist(entry) else { return nil }
            return entry
        }
        return entries.prefix(WatchGridWire.limit).map { entry in
            WatchGridWire.Tile(id: entry.id,
                               label: entry.label,
                               icon: entry.icon,
                               takesPhoto: entry.capturesPhoto,
                               dimmed: photoBlocked && entry.capturesPhoto)
        }
    }

    /// My Manuals opens a picker on the phone's screen, which a wrist cannot answer.
    private static func runsFromWrist(_ entry: HomeGridEntry) -> Bool {
        if case .quickAction(let action) = entry { return action.id != QuickAction.myManuals.id }
        return true
    }

    /// What a tap runs on the phone.
    enum Route: Equatable {
        /// A canned question, asked as a typed turn.
        case textTurn(prompt: String)
        /// A question about a glasses photo.
        case photoTurn(prompt: String)
        /// A glasses photo, described.
        case photo
        /// A speed-dial action the phone runs as its own tile does.
        case quickAction(QuickAction)
        /// Not run, and why, in words for the wrist.
        case refused(String)
    }

    static func route(entryId: String?,
                      quickActions: [QuickAction],
                      photoBlocked: Bool,
                      glassesConnected: Bool) -> Route {
        guard let entryId,
              let entry = HomeGridCatalog.entry(id: entryId, quickActions: quickActions),
              runsFromWrist(entry) else {
            return .refused(String(localized: "That action is no longer on your grid."))
        }
        if entry.capturesPhoto && photoBlocked {
            return .refused(String(localized: "The model you're using can't look at photos."))
        }
        switch entry {
        case .builtIn(let action):
            switch action.kind {
            case .prompt: return .textTurn(prompt: action.prompt)
            case .photoPrompt: return .photoTurn(prompt: action.prompt)
            }
        case .quickAction(let action):
            switch action.type {
            case .photo:
                return .photo
            case .photoThenPrompt:
                return .photoTurn(prompt: action.promptText ?? "Describe what you see.")
            case .prompt:
                if PhoneCapturePolicy.preCaptureHint(forQuickAction: action.id,
                                                     glassesConnected: glassesConnected) != nil {
                    return .refused(String(localized: "Connect your glasses to run this from your watch."))
                }
                return .quickAction(action)
            case .homeAssistant, .siriShortcut, .openApp, .toggleRecording:
                return .quickAction(action)
            }
        }
    }
}
