import Foundation

// Plan NE P0 — the settings someone keeps at the top of the hub. Pins are per phone and set by no
// organisation profile (decision 4), at most eight (decision 5). A pin whose entry becomes hidden
// is kept and not drawn (decision 6): it comes back when the screen does, and a technician never
// sees it in the meantime, because what is drawn is resolved through `SettingsIndex.visible`.

/// An ordered list of index ids.
struct SettingsPins: Equatable, Sendable {
    static let limit = 8

    private(set) var ids: [String]

    /// Duplicates, ids the index does not know (an entry since removed) and anything past the limit
    /// are dropped as the list is read.
    init(ids: [String] = [], known: Set<String> = SettingsIndex.ids) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { known.contains($0) && seen.insert($0).inserted }.prefix(Self.limit))
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    var isFull: Bool { ids.count >= Self.limit }

    /// Adds `id` at the end. False when it is already pinned, unknown, or the list is full.
    @discardableResult
    mutating func pin(_ id: String, known: Set<String> = SettingsIndex.ids) -> Bool {
        guard !isFull, !contains(id), known.contains(id) else { return false }
        ids.append(id)
        return true
    }

    mutating func unpin(_ id: String) {
        ids.removeAll { $0 == id }
    }

    /// Pins `id`, or unpins it when it is pinned already.
    mutating func toggle(_ id: String, known: Set<String> = SettingsIndex.ids) {
        if contains(id) { unpin(id) } else { pin(id, known: known) }
    }

    /// Moves `id` one place up. With `visible`, it passes the previous pin that is drawn, so a pin
    /// kept while hidden never makes a move look like nothing happened.
    mutating func move(up id: String, among visible: [String]? = nil) {
        move(id, by: -1, among: visible)
    }

    mutating func move(down id: String, among visible: [String]? = nil) {
        move(id, by: 1, among: visible)
    }

    private mutating func move(_ id: String, by step: Int, among visible: [String]?) {
        let order = visible.map { shown in ids.filter { shown.contains($0) } } ?? ids
        guard let position = order.firstIndex(of: id), order.indices.contains(position + step),
              let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: order[position + step])
        else { return }
        ids.swapAt(from, to)
    }

    /// The pinned entries this person may see, in pin order.
    func visible(in conditions: SettingsSearchConditions) -> [SettingsIndexEntry] {
        let shown = Dictionary(uniqueKeysWithValues: SettingsIndex.visible(in: conditions).map { ($0.id, $0) })
        return ids.compactMap { shown[$0] }
    }

    /// Whether the move would change anything, for the context menu.
    func canMove(up id: String, among visible: [String]) -> Bool {
        visible.firstIndex(of: id).map { $0 > 0 } ?? false
    }

    func canMove(down id: String, among visible: [String]) -> Bool {
        visible.firstIndex(of: id).map { $0 < visible.count - 1 } ?? false
    }
}

/// Where the pins are kept: a list of ids in the `UserDefaults` it is given, so tests use a suite
/// of their own.
struct SettingsPinStore {
    static let key = "settingsPinnedEntries"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SettingsPins {
        SettingsPins(ids: defaults.stringArray(forKey: Self.key) ?? [])
    }

    func save(_ pins: SettingsPins) {
        defaults.set(pins.ids, forKey: Self.key)
    }
}
