import Foundation

// The watch's home screen: the phone's first grid tiles, and which of the More screen's items the
// wearer keeps on the main screen as well. Foundation only and compiled into both targets (listed
// in `project.watch.yml`), so the phone that sends the tiles and runs a tap, and the watch that
// draws them, read the same keys and the same rules.

/// The phone's home grid on the wrist: its first tiles, in the phone's own order, drawn three
/// across as the phone draws them.
enum WatchGridWire {
    /// The application-context key the tiles travel under. A phone too old to send it sends only
    /// the legacy `quickActions` list, and the watch draws that instead.
    static let contextKey = "gridTiles"
    /// The message command a tap sends.
    static let command = "gridTile"
    /// The key the tapped tile's id travels under: the grid's own entry id (`builtin:…`/`quick:…`).
    static let entryIdKey = "entry_id"
    /// The phone's width.
    static let columns = 3
    /// Four rows of three.
    static let limit = 12

    struct Tile: Equatable, Identifiable {
        /// The grid entry id the phone resolves a tap against.
        let id: String
        let label: String
        /// An SF Symbol name.
        let icon: String
        /// Running it takes a picture first.
        let takesPhoto: Bool
        /// The phone dims it too: a photo tile while the model in use cannot see.
        let dimmed: Bool
    }

    static func encode(_ tiles: [Tile]) -> [[String: String]] {
        tiles.prefix(limit).map { tile in
            [
                "id": tile.id,
                "label": tile.label,
                "icon": tile.icon,
                "photo": tile.takesPhoto ? "1" : "0",
                "dimmed": tile.dimmed ? "1" : "0",
            ]
        }
    }

    /// The tiles a context carries; nil when it carries none (an older phone). Peer-supplied, so a
    /// tile without an id or a label is dropped rather than drawn blank, and no more than `limit`
    /// are kept whatever arrives.
    static func decode(_ value: Any?) -> [Tile]? {
        guard let rows = value as? [[String: String]] else { return nil }
        let tiles: [Tile] = rows.compactMap { row in
            guard let id = row["id"], !id.isEmpty,
                  let label = row["label"], !label.isEmpty else { return nil }
            let icon = row["icon"].flatMap { $0.isEmpty ? nil : $0 } ?? "star.fill"
            return Tile(id: id, label: label, icon: icon,
                        takesPhoto: row["photo"] == "1", dimmed: row["dimmed"] == "1")
        }
        return Array(tiles.prefix(limit))
    }

    /// The message a tap sends.
    static func message(tileId: String) -> [String: Any] {
        ["command": command, entryIdKey: tileId]
    }
}

/// The More screen's items the wearer also keeps on the main screen, above More. Pinning adds an
/// item to the main screen; it stays under More as well, so it can always be found in one place.
enum WatchMorePins {
    /// The watch's own defaults key. The pins are the wearer's arrangement of this watch, so they
    /// stay on it and are never sent to the phone.
    static let storageKey = "watchMorePins"

    /// What can be pinned. A persona is named by its id; the rest are fixed.
    enum Item: Hashable, Identifiable {
        case privateConversation
        case connection
        case persona(id: String)

        var id: String { token }

        var token: String {
            switch self {
            case .privateConversation: return "private"
            case .connection: return "connection"
            case .persona(let id): return "persona:\(id)"
            }
        }

        init?(token: String) {
            switch token {
            case "private": self = .privateConversation
            case "connection": self = .connection
            default:
                let prefix = "persona:"
                guard token.hasPrefix(prefix) else { return nil }
                let id = String(token.dropFirst(prefix.count))
                guard !id.isEmpty else { return nil }
                self = .persona(id: id)
            }
        }
    }

    /// The pinned items in the order they were pinned. Unknown and repeated tokens are dropped, so
    /// a value written by a newer build reads as what this one understands.
    static func decode(_ stored: String) -> [Item] {
        var seen = Set<Item>()
        return stored.split(separator: ",").compactMap { Item(token: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    static func encode(_ items: [Item]) -> String {
        items.map(\.token).joined(separator: ",")
    }

    /// Pins an item at the end, or unpins it.
    static func toggling(_ item: Item, in stored: String) -> String {
        var items = decode(stored)
        if let index = items.firstIndex(of: item) {
            items.remove(at: index)
        } else {
            items.append(item)
        }
        return encode(items)
    }

    /// What the main screen draws: the pins that can be drawn now. A pinned persona the phone no
    /// longer offers is skipped, not dropped, so it comes back if the phone offers it again.
    static func shown(_ stored: String, personaIds: [String]) -> [Item] {
        let offered = Set(personaIds)
        return decode(stored).filter { item in
            if case .persona(let id) = item { return offered.contains(id) }
            return true
        }
    }
}
