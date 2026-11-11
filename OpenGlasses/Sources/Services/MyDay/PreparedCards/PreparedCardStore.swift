import Foundation

// Plan KT §3.5 — what the wearer did with each card, kept per card id: its state, their edit of its
// draft and when either last changed. No chips, no facts, no recipient. An entry goes 24 h after
// its card's `validUntil`.
//
// One JSON file, `Application Support/PreparedCards/cards.json`, loaded at construction and written
// on every change. First-unlock protection — a card can be handed off and come back while the phone
// locks — and excluded from backup, because the subject-erasure walk reaches it: an edited draft
// can name the person it is to. Registered in `DataStoreRegistry` as `preparedCards`.

/// One card's entry.
struct PreparedCardStoreEntry: Codable, Equatable, Sendable {
    var memory: PreparedCardMemory
    /// The card's `validUntil` plus a day: when this entry goes.
    var expiresAt: Date
    /// The draft text the wearer's edit started from, so a rebuild whose times changed can say so
    /// ("Times changed — update draft?") without overwriting the edit (§5.4). Present only while
    /// there is an edit.
    var editedFrom: String?
}

/// "Later" (§3.5): in an hour, this evening, tomorrow morning — each only when the card is still
/// valid by then.
enum PreparedCardLaterOption: String, CaseIterable, Sendable {
    case inAnHour
    case thisEvening
    case tomorrowMorning

    /// This evening starts at 18:00; tomorrow morning at 08:00.
    static let eveningHour = 18
    static let morningHour = 8

    var label: String {
        switch self {
        case .inAnHour: String(localized: "In an hour", comment: "My Day card: put the card off for an hour.")
        case .thisEvening: String(localized: "This evening", comment: "My Day card: put the card off until the evening.")
        case .tomorrowMorning: String(localized: "Tomorrow morning", comment: "My Day card: put the card off until tomorrow morning.")
        }
    }

    /// When the card comes back, or nil when the option does not apply now (this evening, once it
    /// is evening).
    func until(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .inAnHour:
            return now.addingTimeInterval(3600)
        case .thisEvening:
            guard let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: now),
                  evening > now.addingTimeInterval(15 * 60) else { return nil }
            return evening
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: tomorrow)
        }
    }

    /// The options a card valid until `validUntil` can offer at `now`.
    static func available(validUntil: Date, now: Date, calendar: Calendar) -> [PreparedCardLaterOption] {
        allCases.filter { option in
            guard let until = option.until(now: now, calendar: calendar) else { return false }
            return until < validUntil
        }
    }
}

/// §3.5: three "not useful" on one kind within 14 days turns that kind off.
enum PreparedCardKindSuppression {
    static let window: TimeInterval = 14 * 86_400
    static let threshold = 3

    /// The presses still inside the window.
    static func recent(_ presses: [Date], now: Date) -> [Date] {
        presses.filter { now.timeIntervalSince($0) < window && $0 <= now.addingTimeInterval(60) }
    }

    static func shouldTurnOff(_ presses: [Date], now: Date) -> Bool {
        recent(presses, now: now).count >= threshold
    }
}

@MainActor
final class PreparedCardStore: ObservableObject {

    static let shared = PreparedCardStore()

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    /// An entry outlives its card by this much, so a card rebuilt just after it ended does not
    /// come back fresh.
    nonisolated static let retentionAfterCard: TimeInterval = 24 * 3600

    private struct File: Codable {
        var version: Int
        var entries: [String: PreparedCardStoreEntry]
        /// Each kind's "not useful" presses, for §3.5's turn-off rule. Times only.
        var notUseful: [String: [Date]]
    }

    private static let formatVersion = 1

    /// By card id (`PreparedCardID.rawValue`).
    @Published private(set) var entries: [String: PreparedCardStoreEntry] = [:]
    @Published private(set) var notUsefulPresses: [PreparedCardKind: [Date]] = [:]

    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("cards.json")
        reload()
    }

    nonisolated static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("PreparedCards", isDirectory: true)
    }

    /// What the joiner reads.
    var memory: [PreparedCardID: PreparedCardMemory] {
        var result: [PreparedCardID: PreparedCardMemory] = [:]
        for (raw, entry) in entries {
            guard let id = PreparedCardID(rawValue: raw) else { continue }
            result[id] = entry.memory
        }
        return result
    }

    func entry(for id: PreparedCardID) -> PreparedCardStoreEntry? { entries[id.rawValue] }

    // MARK: - Changes

    /// Set a card's state, keeping any edit.
    func record(_ state: PreparedCardState, for card: PreparedCard, now: Date) {
        var entry = entries[card.id.rawValue] ?? Self.newEntry(for: card, now: now)
        entry.memory.state = state
        entry.memory.changedAt = now
        entry.expiresAt = card.validUntil.addingTimeInterval(Self.retentionAfterCard)
        entries[card.id.rawValue] = entry
        save()
    }

    /// Mark cards seen on the page. Only a fresh card moves; nothing is written otherwise.
    func markSeen(_ cards: [PreparedCard], now: Date) {
        var changed = false
        for card in cards {
            let current = entries[card.id.rawValue]
            guard current == nil || current?.memory.state == .fresh else { continue }
            var entry = current ?? Self.newEntry(for: card, now: now)
            entry.memory.state = .seen
            entry.memory.changedAt = now
            entries[card.id.rawValue] = entry
            changed = true
        }
        if changed { save() }
    }

    /// Keep the wearer's edit of a card's draft. `base` is the text the edit started from. An
    /// edit back to the base text, or to nothing, drops the edit.
    func setEdit(_ text: String?, base: String, for card: PreparedCard, now: Date) {
        var entry = entries[card.id.rawValue] ?? Self.newEntry(for: card, now: now)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || text == base {
            entry.memory.editedText = nil
            entry.editedFrom = nil
        } else {
            entry.memory.editedText = text
            if entry.editedFrom == nil { entry.editedFrom = base }
        }
        entry.memory.changedAt = now
        entry.expiresAt = card.validUntil.addingTimeInterval(Self.retentionAfterCard)
        entries[card.id.rawValue] = entry
        save()
    }

    /// "Update" on "Times changed — update draft?": the edit goes and the new draft shows.
    func dropEdit(for id: PreparedCardID, now: Date) {
        guard var entry = entries[id.rawValue] else { return }
        entry.memory.editedText = nil
        entry.editedFrom = nil
        entry.memory.changedAt = now
        entries[id.rawValue] = entry
        save()
    }

    /// "Keep mine": the edit stays, and is now measured against the new draft.
    func keepEdit(for id: PreparedCardID, newBase: String, now: Date) {
        guard var entry = entries[id.rawValue], entry.memory.editedText != nil else { return }
        entry.editedFrom = newBase
        entry.memory.changedAt = now
        entries[id.rawValue] = entry
        save()
    }

    /// Undo a dismissal, a "later", a "done" or a "not useful": the card is fresh again, its edit
    /// kept.
    func restore(_ id: PreparedCardID, now: Date) {
        guard var entry = entries[id.rawValue] else { return }
        entry.memory.state = .fresh
        entry.memory.changedAt = now
        entries[id.rawValue] = entry
        save()
    }

    /// "Not useful": the card goes, and the press counts towards turning the kind off. Returns
    /// true when this press is the one that should turn the kind off.
    @discardableResult
    func notUseful(_ card: PreparedCard, now: Date) -> Bool {
        var presses = PreparedCardKindSuppression.recent(notUsefulPresses[card.kind] ?? [], now: now)
        presses.append(now)
        notUsefulPresses[card.kind] = presses
        var entry = entries[card.id.rawValue] ?? Self.newEntry(for: card, now: now)
        entry.memory.state = .notUseful
        entry.memory.changedAt = now
        entries[card.id.rawValue] = entry
        save()
        return PreparedCardKindSuppression.shouldTurnOff(presses, now: now)
    }

    /// The Undo on "turned off": the kind's presses are forgotten so it is not turned off again by
    /// the next one.
    func clearNotUseful(_ kind: PreparedCardKind) {
        guard notUsefulPresses[kind] != nil else { return }
        notUsefulPresses[kind] = nil
        save()
    }

    /// Entries whose card ended more than a day ago go, and presses older than the window.
    func prune(now: Date) {
        let keptEntries = entries.filter { $0.value.expiresAt > now }
        var keptPresses: [PreparedCardKind: [Date]] = [:]
        for (kind, presses) in notUsefulPresses {
            let recent = PreparedCardKindSuppression.recent(presses, now: now)
            if !recent.isEmpty { keptPresses[kind] = recent }
        }
        guard keptEntries.count != entries.count || keptPresses != notUsefulPresses else { return }
        entries = keptEntries
        notUsefulPresses = keptPresses
        save()
    }

    // MARK: - Erasure

    /// Everything — the registry's "delete all".
    func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
        entries = [:]
        notUsefulPresses = [:]
    }

    /// For a subject erasure: every entry whose kept draft text names `token` goes whole. Returns
    /// how many went.
    @discardableResult
    func forget(matching token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let kept = entries.filter { _, entry in
            ![entry.memory.editedText, entry.editedFrom].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        entries = kept
        save()
        return removed
    }

    // MARK: - Storage

    private static func newEntry(for card: PreparedCard, now: Date) -> PreparedCardStoreEntry {
        PreparedCardStoreEntry(memory: PreparedCardMemory(changedAt: now),
                               expiresAt: card.validUntil.addingTimeInterval(retentionAfterCard))
    }

    /// Read the file again — after an unlock, when it may have become readable.
    func reload() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? RecordJSONCodec.decoder().decode(File.self, from: data),
              file.version == Self.formatVersion else {
            entries = [:]
            notUsefulPresses = [:]
            return
        }
        entries = file.entries
        var presses: [PreparedCardKind: [Date]] = [:]
        for (raw, dates) in file.notUseful {
            if let kind = PreparedCardKind(rawValue: raw) { presses[kind] = dates }
        }
        notUsefulPresses = presses
    }

    private func save() {
        let file = File(version: Self.formatVersion, entries: entries,
                        notUseful: Dictionary(uniqueKeysWithValues: notUsefulPresses.map { ($0.key.rawValue, $0.value) }))
        guard let data = try? RecordJSONCodec.encoder().encode(file) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        StoreProtection.apply(Self.fileProtection, backupExcluded: true, to: fileURL)
    }
}
