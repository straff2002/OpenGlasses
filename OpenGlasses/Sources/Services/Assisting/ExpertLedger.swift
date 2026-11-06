import Foundation
import Combine

/// One time reply the expert sent, as their own ledger keeps it (Plan KM §7, P4): which
/// organisation, which job, when, and the minutes. **No rate**: the expert's side never has the
/// organisation's rate, and the ledger is minutes only. Nothing of the job beyond its reference.
struct ExpertLedgerEntry: Codable, Equatable, Identifiable, Sendable {
    let handoverId: String
    /// As the handover named it; the ledger groups by it, one organisation at a time.
    let organisation: String
    let jobReference: String?
    let acceptedAt: Date
    let doneAt: Date
    let minutes: Int
    let uncountedMinutes: Int
    let callMinutes: Int?
    let sentAt: Date

    var id: String { handoverId }

    var organisationKey: String { HeldHandover.organisationKey(organisation) }

    init(reply: ExpertTimeReply, sentAt: Date) {
        handoverId = reply.handoverId
        organisation = reply.organisation
        jobReference = reply.jobReference
        acceptedAt = reply.acceptedAt
        doneAt = reply.doneAt
        minutes = reply.minutes
        uncountedMinutes = reply.uncountedMinutes
        callMinutes = reply.callMinutes
        self.sentAt = sentAt
    }
}

/// The expert's own month, by organisation (Plan KM §7, P4): built from the time replies they
/// sent, exported one organisation at a time, as CSV and PDF, so they can invoice each company
/// from their own record. Pure.
///
/// **Minutes only, and one organisation per export.** It has no rate — the organisation keeps
/// that, on its `ExpertStatement` — and no way to put two organisations in one document: every
/// document is asked for by one organisation's key and filters to it. The organisation's statement
/// is built from the same replies, so the two should agree; a difference points at a reply one
/// side never got.
struct ExpertLedger: Equatable, Sendable {

    let entries: [ExpertLedgerEntry]

    struct Organisation: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    /// One row per organisation, by name.
    var organisations: [Organisation] {
        let byKey = Dictionary(grouping: entries, by: \.organisationKey)
        return byKey.keys.sorted().map { key in
            let newest = byKey[key]!.max { $0.doneAt < $1.doneAt }
            return Organisation(id: key, name: newest?.organisation ?? key)
        }
    }

    /// The months one organisation has time in, newest first.
    func months(organisation key: String, calendar: Calendar) -> [CalendarMonth] {
        let months = entries.filter { $0.organisationKey == key }.map { CalendarMonth($0.doneAt, calendar: calendar) }
        return Array(Set(months)).sorted(by: >)
    }

    /// One organisation's jobs in a month, in date order. Never another organisation's.
    func rows(organisation key: String, month: CalendarMonth, calendar: Calendar) -> [ExpertLedgerEntry] {
        entries.filter { $0.organisationKey == key && month.contains($0.doneAt, calendar: calendar) }
            .sorted { ($0.doneAt, $0.handoverId) < ($1.doneAt, $1.handoverId) }
    }

    func totalMinutes(organisation key: String, month: CalendarMonth, calendar: Calendar) -> Int {
        rows(organisation: key, month: month, calendar: calendar).reduce(0) { $0 + $1.minutes }
    }

    static let rateNote = "No rate or amount: the organisation keeps your rate, on its own statement of the same replies."
    static let paymentNote = "The app never takes or sends a payment."

    func document(organisation key: String, month: CalendarMonth, calendar: Calendar, preparedAt: Date) -> MinutesTableDocument {
        let rows = rows(organisation: key, month: month, calendar: calendar)
        let name = organisations.first { $0.id == key }?.name ?? key
        let total = rows.reduce(0) { $0 + $1.minutes }
        let calls = rows.compactMap(\.callMinutes)
        return MinutesTableDocument(
            title: "Your time for \(name.isEmpty ? "an organisation" : name) — \(month.title)",
            lede: ["From the time replies you sent to \(name.isEmpty ? "this organisation" : name). This organisation only.",
                   "Prepared \(MinutesTableDocument.isoDay(preparedAt, calendar: calendar)). Minutes are your clock, Take this job to Done.",
                   Self.rateNote],
            columns: ["Date", "Job", "Minutes", "Call minutes", "Not counted"],
            rows: rows.map { entry in
                [MinutesTableDocument.isoDay(entry.doneAt, calendar: calendar), entry.jobReference ?? "",
                 String(entry.minutes), MinutesTableDocument.minutes(entry.callMinutes),
                 entry.uncountedMinutes > 0 ? String(entry.uncountedMinutes) : ""]
            },
            total: ["Total", "\(rows.count) job\(rows.count == 1 ? "" : "s")", String(total),
                    calls.isEmpty ? "" : String(calls.reduce(0, +)), ""],
            notes: [Self.paymentNote])
    }

    func fileStem(organisation key: String, month: CalendarMonth) -> String {
        let name = organisations.first { $0.id == key }?.name ?? key
        return MinutesTableDocument.fileStem(["time", name, month.id])
    }
}

/// Where the expert's ledger lives (Plan KM P4): one JSON file in Application Support/Assisting,
/// beside the handovers but kept longer than any of them — a month's invoicing outlives a
/// handover's thirty days.
///
/// **The expert's own record, and nothing else reads it.** Only Assisting writes it, on a time
/// reply's completed share; never `BrainStore`, threads, team learnings or search
/// (`AssistingIsolationTests`). Registered in `DataStoreRegistry` as `expertLedger`: the
/// expert's own business record (organisation names, job references, dates and minutes; no
/// customer, no unit, no words), protected first-unlock like the handovers and, like them, out of
/// backup. Rows older than `retentionDays` go, and at most `entryCap` are kept.
@MainActor
final class ExpertLedgerStore: ObservableObject {

    static let shared = ExpertLedgerStore()

    nonisolated static let entryCap = 2_000
    /// Thirteen months: a year of invoices, and the month before it.
    nonisolated static let retentionDays = 400

    @Published private(set) var entries: [ExpertLedgerEntry]

    private let url: URL
    private let now: () -> Date

    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        let folder = directory ?? AssistingLedgerLocation.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("ledger.json")
        self.now = now
        entries = Self.read(url) ?? []
        if prune() { save() }
    }

    var ledger: ExpertLedger { ExpertLedger(entries: entries) }

    /// A time reply's share completed: it goes on the ledger. The same handover sent again replaces
    /// its row.
    func record(_ reply: ExpertTimeReply, sentAt: Date) {
        entries.removeAll { $0.handoverId == reply.handoverId }
        entries.append(ExpertLedgerEntry(reply: reply, sentAt: sentAt))
        _ = prune()
        save()
        PrivacyLog.store(.expertLedger, .recordWritten, count: entries.count)
    }

    /// Everything — what the registry's "delete all" column names.
    func removeAll() {
        let count = entries.count
        entries = []
        try? FileManager.default.removeItem(at: url)
        if count > 0 { PrivacyLog.store(.expertLedger, .cleared, count: count) }
    }

    /// Where the file lives, for the attribute-truth test.
    var fileLocation: URL { url }

    @discardableResult
    private func prune() -> Bool {
        let before = entries.count
        let cutoff = now().addingTimeInterval(-TimeInterval(Self.retentionDays) * 86_400)
        entries.removeAll { $0.doneAt < cutoff }
        if entries.count > Self.entryCap {
            entries = Array(entries.sorted { $0.doneAt < $1.doneAt }.suffix(Self.entryCap))
        }
        return entries.count != before
    }

    private static func read(_ url: URL) -> [ExpertLedgerEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try ExpertHandoverFile.decoder().decode([ExpertLedgerEntry].self, from: data)
        } catch {
            PrivacyLog.store(.expertLedger, .loadFailed, error: SafeErrorSummary(error))
            return nil
        }
    }

    private func save() {
        guard let data = try? ExpertHandoverFile.encoder().encode(entries) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PrivacyLog.store(.expertLedger, .saveFailed, error: SafeErrorSummary(error))
        }
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

/// The folder the expert's side keeps its files in.
enum AssistingLedgerLocation {
    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Assisting", isDirectory: true)
    }
}
