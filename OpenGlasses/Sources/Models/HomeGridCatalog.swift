import CoreGraphics
import Foundation

/// One shipped action on the Voice tab's home grid.
///
/// Actions are data, not view literals: the grid draws this catalog, the editor arranges it, and
/// every entry resolves through the normal turn pipeline. A `.prompt` is a user turn the user did
/// not have to type; a `.photoPrompt` is the same turn with a still attached. Nothing here calls a
/// tool — the model reaches `calendar` and `reminder` from these turns exactly as it does from
/// speech, so a tile can never do something the wearer could not have asked for.
struct HomeGridAction: Identifiable, Equatable, Codable {
    /// Two kinds, deliberately. Anything that needs a third is a speed-dial `QuickAction`, which
    /// the grid also carries — this type is only the canned-turn half of the catalog.
    enum Kind: String, Codable, Equatable {
        case prompt
        case photoPrompt
    }

    /// Stable across releases: it is what the arrangement persists.
    let id: String
    let label: String
    let icon: String
    let kind: Kind
    /// The user turn this action submits.
    let prompt: String
}

extension HomeGridAction {
    static let meetingsToday = HomeGridAction(
        id: "meetings-today",
        label: "Meetings",
        icon: "calendar",
        kind: .prompt,
        prompt: "What is left on my calendar today? Give me each meeting with its time and where "
              + "it is, one short line each, soonest first.")

    static let tasksToday = HomeGridAction(
        id: "tasks-today",
        label: "Tasks",
        icon: "checklist",
        kind: .prompt,
        prompt: "What reminders are due today? List them briefly, most urgent first, and say if "
              + "anything is already overdue.")

    static let photoToEvent = HomeGridAction(
        id: "photo-to-event",
        label: "Photo → Event",
        icon: "calendar.badge.plus",
        kind: .photoPrompt,
        prompt: "Read this image and create a calendar event from the date, time, place and title "
              + "you find in it. Ask me only if the date or time is genuinely ambiguous, then tell "
              + "me what you created.")

    static let photoToTask = HomeGridAction(
        id: "photo-to-task",
        label: "Photo → Task",
        icon: "text.badge.plus",
        kind: .photoPrompt,
        prompt: "Read this image and add the action items you find in it to my reminders, with due "
              + "dates where the image gives one. Tell me what you added.")

    /// The grid as it ships.
    static let builtIns: [HomeGridAction] = [meetingsToday, tasksToday, photoToEvent, photoToTask]
}

// MARK: - Grid entries

/// A slot in the home grid — a shipped action, or one of the user's speed-dial actions, which
/// used to ride the dock's scrolling row and keeps its shipped behaviour here.
enum HomeGridEntry: Identifiable, Equatable {
    case builtIn(HomeGridAction)
    case quickAction(QuickAction)

    /// Namespaced, so a speed-dial action can never collide with a shipped one in the arrangement.
    var id: String {
        switch self {
        case .builtIn(let action): return "builtin:\(action.id)"
        case .quickAction(let action): return "quick:\(action.id)"
        }
    }

    var label: String {
        switch self {
        case .builtIn(let action): return action.label
        case .quickAction(let action): return action.label
        }
    }

    var icon: String {
        switch self {
        case .builtIn(let action): return action.icon
        case .quickAction(let action): return action.icon
        }
    }

    /// Whether running this entry takes a picture first. The grid needs it to gate photo tiles on
    /// a model that cannot see, and VoiceOver needs it because a camera is the one thing a tile
    /// does that the wearer has to be ready for.
    var capturesPhoto: Bool {
        switch self {
        case .builtIn(let action): return action.kind == .photoPrompt
        case .quickAction(let action): return action.type == .photo || action.type == .photoThenPrompt
        }
    }

    /// What VoiceOver says a tile will do. The camera is the difference a hint has to carry; the
    /// drawn glyph is the only other place it exists.
    var spokenHint: String {
        if capturesPhoto { return "Takes a photo, then asks about it." }
        switch self {
        case .builtIn:
            return "Double-tap to ask."
        case .quickAction(let action):
            switch action.type {
            case .prompt: return "Double-tap to ask."
            case .homeAssistant: return "Double-tap to run this home control."
            case .siriShortcut: return "Double-tap to run this shortcut."
            case .openApp: return "Double-tap to open the app."
            case .toggleRecording: return "Double-tap to start or stop recording."
            case .photo, .photoThenPrompt: return "Takes a photo, then asks about it."
            }
        }
    }
}

// MARK: - Arrangement

/// The user's arrangement of the home grid, persisted as one small versioned record.
///
/// Removal is a *hide*: the action behind a removed tile is untouched, so a speed-dial action
/// taken off the grid is still in Settings, still on the widget and the watch, and still
/// reachable by voice. Nothing in this type can delete a user's data.
struct HomeGridArrangement: Codable, Equatable {
    static let currentVersion = 1

    var version: Int = currentVersion
    /// Entry ids in the order the grid draws them. Ids this build has no entry for are dropped on
    /// decode; anything available but unmentioned appends, so new built-ins and newly added
    /// speed-dial actions reach an existing arrangement.
    var order: [String] = []
    /// Entries the user took off the grid.
    var hidden: [String] = []

    /// The shipped arrangement: no explicit order, nothing hidden — the catalog's own order.
    static let `default` = HomeGridArrangement()
}

/// Pure composition and order arithmetic for the home grid, so the migration and the salvage rules
/// are provable without a screen — the shape `DockLayout` gives the dock.
///
/// There is no visible ceiling. The grid wraps into rows of four and scrolls vertically inside the
/// dock panel once it outgrows its bounded height, so an entry is never silently cut off; what the
/// grid holds is the editor's business, not the layout's.
enum HomeGridCatalog {
    /// Everything the editor can offer: the shipped actions, then the user's speed dial.
    static func available(quickActions: [QuickAction]) -> [HomeGridEntry] {
        HomeGridAction.builtIns.map(HomeGridEntry.builtIn)
            + quickActions.map(HomeGridEntry.quickAction)
    }

    /// The grid an arrangement resolves to, against what this build actually has: the stored order
    /// wins, unknown and duplicate ids vanish, hidden entries stay off, and anything available the
    /// order never mentioned appends in catalog order.
    static func entries(arrangement: HomeGridArrangement,
                        quickActions: [QuickAction]) -> [HomeGridEntry] {
        let catalog = available(quickActions: quickActions)
        let byId = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hidden = Set(arrangement.hidden)

        var placed = Set<String>()
        var result: [HomeGridEntry] = []
        for id in arrangement.order {
            guard let entry = byId[id], !placed.contains(id), !hidden.contains(id) else { continue }
            placed.insert(id)
            result.append(entry)
        }
        for entry in catalog where !placed.contains(entry.id) && !hidden.contains(entry.id) {
            result.append(entry)
        }
        return result
    }

}

// MARK: - The dock's one grid

/// The dock grid's metrics, in one place because two views have to agree on them exactly.
///
/// The panel sizes itself to a whole number of rows. It used to take a single scaled constant as its
/// maximum height, which landed mid-tile — on device that read as one and three-quarter rows, with
/// the fourth row's tiles sliced across the panel's edge. A partial tile is not a smaller control,
/// it is an unreachable one, so the height is always `n` complete rows and everything past them is
/// a scroll rather than a crop. That only stays true while the row height the panel snaps to is the
/// tile height the tile actually draws, which is why the floor and the spacing live here rather than
/// as literals inside `BarButton`.
enum DockGridMetrics {
    /// `BarButton`'s height floor — the fingertip minimum, before Dynamic Type grows the content
    /// past it.
    static let tileMinHeight: CGFloat = 48
    static let tileMinWidth: CGFloat = 58
    /// The tile's glyph box and its one caption line, at the default text size. Both are scaled by
    /// the views that draw and measure them; what has to be shared is the base.
    ///
    /// The caption base is a point or two *above* the real line height of `.caption`, deliberately.
    /// The two failures are not symmetric: an estimate that runs high leaves a hairline of empty
    /// glass under the last row, and one that runs low clips the last row's tiles — which is the
    /// bug this whole type exists to prevent.
    static let tileGlyphBox: CGFloat = 28
    static let tileCaptionLine: CGFloat = 18

    /// The square a bundled provider mark is drawn into.
    ///
    /// A tile's SF symbol is drawn at `.callout` — about 16 pt of ink, held up by the stroke
    /// weights and optical corrections every symbol in the family shares. A brand mark has none of
    /// that: it is flat artwork with its own margin baked into its viewBox, so at the symbol's size
    /// it reads visibly lighter and, on device, simply too small to recognise. It takes most of the
    /// tile's glyph box instead — roughly 1.25× the symbol beside it, which is what makes the two
    /// read at one weight in the same row, and still inside the box so the badge overlay clears it.
    static let markGlyphBox: CGFloat = 24

    /// Room the page control needs under the pages it indexes, so no tile or transcript line sits
    /// beneath the dots.
    ///
    /// Measured against the dots as drawn, not guessed: SwiftUI centres its page index view inside
    /// the bottom of the tab view's bounds rather than sitting it below them, so reserving only the
    /// capsule's own height still left it overlapping the last row's captions by a few points.
    static let pageIndicatorHeight: CGFloat = 40
    /// Gap between the glyph and the caption inside a tile.
    static let tileStackSpacing: CGFloat = 3
    /// Gap between tiles, in both axes.
    static let rowSpacing: CGFloat = 4

    /// The most rows the grid ever rests at. Beyond that it scrolls.
    static let defaultVisibleRows = 4

    /// The share of the tab's height the panel may take at rest, and the reason it is two numbers.
    ///
    /// The panel is the bottom of a screen that still has a status card and My Day on it, and on a
    /// phone those three cannot all have what they want: four rows plus an expanded My Day is more
    /// than a 6.9" screen has, and the surface that lost was My Day — clipped mid-card at the
    /// panel's edge. So the ceiling is four rows and the *floor of the screen* decides how many of
    /// them are affordable. Collapsing My Day gives its height back, and the panel is allowed to
    /// take it: that is what the collapse control is for, and it is the one state where a phone
    /// genuinely affords the full four.
    static let restingHeightShare: CGFloat = 0.20
    static let restingHeightShareWhenSurfaceAboveIsCompact: CGFloat = 0.30

    /// Rows the panel rests at: never more than the content needs, never more than the ceiling, and
    /// never more than the screen can spare for it.
    static func restingRows(slotCount: Int, columns: Int, availableHeight: CGFloat,
                            rowHeight: CGFloat, surfaceAboveIsCompact: Bool) -> Int {
        let needed = rowsNeeded(slotCount: slotCount, columns: columns)
        guard rowHeight > 0, availableHeight > 0 else {
            return max(1, min(defaultVisibleRows, needed))
        }
        let share = surfaceAboveIsCompact
            ? restingHeightShareWhenSurfaceAboveIsCompact
            : restingHeightShare
        let affordable = Int((availableHeight * share) / rowHeight)
        return max(1, min(min(defaultVisibleRows, affordable), needed))
    }

    static func rowsNeeded(slotCount: Int, columns: Int) -> Int {
        guard slotCount > 0, columns > 0 else { return 0 }
        return (slotCount + columns - 1) / columns
    }

    /// Rows the panel shows before it starts scrolling. Fewer slots than that shrink the panel —
    /// yielding the content tiles takes rows away, and the conversation zone gets the height back.
    static func visibleRows(slotCount: Int, columns: Int,
                            limit: Int = defaultVisibleRows) -> Int {
        max(1, min(limit, rowsNeeded(slotCount: slotCount, columns: columns)))
    }

    /// The panel's viewport for `rows` complete rows: `n` tiles and the `n - 1` gaps between them,
    /// and never the trailing gap, which is what would let a sliver of the next row show.
    static func gridHeight(rows: Int, tileHeight: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * tileHeight + CGFloat(rows - 1) * rowSpacing
    }
}

/// One slot in the dock panel's wrapped grid.
///
/// The dock used to be controls and the home surface used to carry a second grid of content
/// actions; two grids of identical tiles, one above the other, read as one thing split in half.
/// They are one grid now, and this is what it holds: a control the dock always carries, or a
/// content action that yields with the rest of the home surface.
enum DockSlot: Identifiable, Equatable {
    case control(DockItem)
    case action(HomeGridEntry)

    /// Namespaced against the action ids, which already namespace built-ins against speed dial.
    var id: String {
        switch self {
        case .control(let item): return "control:\(item.rawValue)"
        case .action(let entry): return entry.id
        }
    }

    /// Controls are the dock's job and cannot be taken off it — an arrangement that hides one is
    /// an arrangement that strips the user of the only way to disconnect or switch models.
    var isHideable: Bool {
        if case .control = self { return false }
        return true
    }

    var editorLabel: String {
        switch self {
        case .control(let item): return item.displayName
        case .action(let entry): return entry.label
        }
    }

    var editorIcon: String {
        switch self {
        case .control(let item): return item.icon
        case .action(let entry): return entry.icon
        }
    }
}

/// Pure composition for the dock's single grid: controls in the order the user arranged them,
/// then content actions, all resolved against one stored arrangement.
enum DockGridCatalog {
    /// Every slot this build can draw. `controlOrder` is the user's existing bar arrangement, so a
    /// dock order stored before the two grids merged still leads without a migration step.
    static func available(controlOrder: [DockItem],
                          quickActions: [QuickAction]) -> [DockSlot] {
        controlOrder.map(DockSlot.control)
            + HomeGridCatalog.available(quickActions: quickActions).map(DockSlot.action)
    }

    /// What the dock draws: the stored order wins, unknown and duplicate ids vanish, hidden actions
    /// stay off, hidden *controls* are ignored, and anything available the order never mentioned
    /// appends in catalog order.
    ///
    /// `showsActions` is the home surface's yielding rule reaching the dock — while the assistant
    /// thinks or speaks, while captions are live, and while the mic is open, the content tiles give
    /// their rows back and the controls close up behind them.
    static func slots(arrangement: HomeGridArrangement,
                      controlOrder: [DockItem],
                      quickActions: [QuickAction],
                      showsActions: Bool) -> [DockSlot] {
        let catalog = available(controlOrder: controlOrder, quickActions: quickActions)
        let byId = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hidden = Set(arrangement.hidden)

        func keeps(_ slot: DockSlot) -> Bool {
            switch slot {
            case .control: return true
            case .action: return showsActions && !hidden.contains(slot.id)
            }
        }

        var placed = Set<String>()
        var result: [DockSlot] = []
        for id in arrangement.order {
            guard let slot = byId[id], !placed.contains(id) else { continue }
            placed.insert(id)
            if keeps(slot) { result.append(slot) }
        }
        for slot in catalog where !placed.contains(slot.id) && keeps(slot) {
            result.append(slot)
        }
        return result
    }
}

// MARK: - Persistence

/// Round-trip helpers for the `@AppStorage` string the grid and its editor share, with the
/// element-wise salvage the app's JSON stores keep: a record this build cannot fully honour is
/// repaired rather than discarded, and what it repaired is named in the log.
enum HomeGridStore {
    struct Decoded: Equatable {
        var arrangement: HomeGridArrangement
        /// Ids the stored record named that this build has no entry for. Reported, not swallowed.
        var droppedIds: [String]
    }

    static func encode(_ arrangement: HomeGridArrangement) -> String {
        guard let data = try? JSONEncoder().encode(arrangement),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func decode(_ encoded: String, available: [String]) -> Decoded {
        guard !encoded.isEmpty, let data = encoded.data(using: .utf8) else {
            return Decoded(arrangement: .default, droppedIds: [])
        }
        guard let stored = try? JSONDecoder().decode(HomeGridArrangement.self, from: data) else {
            NSLog("[HomeGrid] Stored arrangement did not decode; falling back to the shipped order")
            return Decoded(arrangement: .default, droppedIds: [])
        }

        let known = Set(available)
        let dropped = (stored.order + stored.hidden).filter { !known.contains($0) }
        if !dropped.isEmpty {
            NSLog("[HomeGrid] Dropping %d entries this build has no action for: %@",
                  dropped.count, dropped.joined(separator: ", "))
        }

        // A record from a version this build doesn't know is still just two lists of ids, so it is
        // salvaged field-wise and re-stamped rather than thrown away.
        var salvaged = HomeGridArrangement()
        salvaged.order = dedupe(stored.order.filter { known.contains($0) })
        salvaged.hidden = dedupe(stored.hidden.filter { known.contains($0) })
        return Decoded(arrangement: salvaged, droppedIds: dropped)
    }

    private static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Running an entry

/// What the home grid needs from the session to run a tile.
///
/// `AppState` is the shipped conformance and every method is an existing seam — the grid adds no
/// entry point of its own. Tests inject a fake, because what has to be provable here is *which*
/// seam an entry reaches, not what the seam then does.
@MainActor
protocol HomeGridSession: AnyObject {
    /// The call `ChatInputBar` makes. A canned tile is a typed turn the user did not type.
    func submitHomePrompt(_ text: String) async
    /// Capture through the glasses camera (phone fallback included), attach the still, submit.
    func submitHomePhotoPrompt(_ text: String) async
    /// Speed-dial actions keep the behaviour they had in the dock, whichever kind they are.
    func runHomeQuickAction(_ action: QuickAction) async
}

/// The one place a grid tile turns into a turn.
enum HomeGridDispatcher {
    static func run(_ entry: HomeGridEntry, on session: HomeGridSession) async {
        switch entry {
        case .builtIn(let action):
            switch action.kind {
            case .prompt:
                await session.submitHomePrompt(action.prompt)
            case .photoPrompt:
                await session.submitHomePhotoPrompt(action.prompt)
            }
        case .quickAction(let action):
            await session.runHomeQuickAction(action)
        }
    }
}
