import Foundation
import Combine
import CryptoKit

/// Where the expert's phone keeps the handovers it was sent (Plan KM §7, P2).
///
/// **Its own store, on purpose, and nothing else reads it.** One JSON index and one folder of
/// photos per handover, in Application Support/Assisting. Never the conversation store, never
/// `BrainStore`, never `DocumentStore` (which retrieval searches), never a vault, never team
/// learnings: a handover is another organisation's job, held under its confidentiality, and an
/// answer for one company must never draw on another company's job. `AssistingIsolationTests`
/// scrapes the sources to hold that: only the Assisting files, the app's wiring and the erasure
/// and retention walks name this type.
///
/// **Each handover carries its own rules** (§7) — the organisation's name and its retention
/// period — so the expert's phone needs nothing from any organisation beforehand. `purgeExpired`
/// applies each one's own period; the retention scheduler calls it.
///
/// Registered in `DataStoreRegistry` as `assistingHandovers`: third-party data (the customer's
/// unit, the technician's words), protected first-unlock (the clock's checkpoint can be written
/// with the phone locked during a call), excluded from backup, and walked by the subject erasure.
@MainActor
final class AssistingHandoverStore: ObservableObject {

    static let shared = AssistingHandoverStore()

    /// A phone that has been sent more than this is not being used as an expert's phone; the
    /// oldest that are Done go first.
    nonisolated static let entryCap = 200

    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    /// Grouped by organisation, newest first inside each.
    @Published private(set) var held: [HeldHandover]

    private let directory: URL
    private let indexURL: URL
    private let now: () -> Date

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Assisting", isDirectory: true)
    }

    /// Opening the store is the relaunch: a clock it finds still running was stopped by the app
    /// dying, and is recovered here, once (§6).
    init(directory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory ?? Self.defaultDirectory()
        self.now = now
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        indexURL = self.directory.appendingPathComponent("handovers.json")
        held = Self.read(indexURL) ?? []
        protect(self.directory)
        recoverClocksAfterRelaunch()
    }

    // MARK: - Reading

    func handover(id: String) -> HeldHandover? { held.first { $0.id == id } }

    /// One organisation's handovers, as the list shows them.
    struct Group: Identifiable, Equatable {
        /// The organisation's key: its name, trimmed and lower-cased.
        let id: String
        /// Its name as the newest handover gives it.
        let organisation: String
        let handovers: [HeldHandover]
    }

    /// One section per organisation, by name; inside each, the newest first. There is no search
    /// across them.
    var groups: [Group] {
        let byKey = Dictionary(grouping: held, by: \.organisationKey)
        return byKey.keys.sorted().map { key in
            let rows = byKey[key]!.sorted { $0.lastReceivedAt > $1.lastReceivedAt }
            return Group(id: key, organisation: rows.first?.organisationName ?? "", handovers: rows)
        }
    }

    /// The photo at `index` of a held handover's latest generation, as the file carried it (already
    /// blurred by the technician's phone).
    func photo(handoverId: String, index: Int) -> Data? {
        guard index >= 0 else { return nil }
        return try? Data(contentsOf: photoURL(handoverId: handoverId, index: index))
    }

    // MARK: - Opening a file

    enum OpenOutcome: Equatable {
        /// The first generation this phone has of it.
        case added
        /// A later generation replaced the one held.
        case replaced(HandoverChanges)
        /// This generation is already held.
        case alreadyHeld
        /// An earlier generation than the one held: kept as it was.
        case olderThanHeld(held: Int)
        /// It claims to update a handover this phone holds, but from another organisation or to
        /// another expert: refused, because a later generation replaces the earlier one only when
        /// it really is the same handover.
        case conflicting
        /// The phone is holding as many as it keeps.
        case full
        /// The photos could not be written on this phone; nothing changed.
        case couldNotSave
    }

    /// Keep an opened handover: a new one, or a later generation of one held (§3). The photos are
    /// written beside it, the index after them.
    @discardableResult
    func open(_ opened: ExpertHandoverFile.Opened) -> OpenOutcome {
        let incoming = opened.handover
        let at = now()
        if let index = held.firstIndex(where: { $0.id == incoming.handoverId }) {
            var current = held[index]
            guard HeldHandover.organisationKey(current.handover.organisation.name)
                    == HeldHandover.organisationKey(incoming.organisation.name),
                  current.handover.expert.id == incoming.expert.id else { return .conflicting }
            if incoming.generation == current.handover.generation { return .alreadyHeld }
            if incoming.generation < current.handover.generation {
                return .olderThanHeld(held: current.handover.generation)
            }
            guard writePhotos(opened) else { return .couldNotSave }
            current.replace(with: incoming, receivedAt: at)
            held[index] = current
            save()
            PrivacyLog.store(.assistingHandovers, .recordWritten, slot: PrivacyToken("replaced"),
                             count: incoming.photos.count)
            return .replaced(current.changes)
        }
        if held.count >= Self.entryCap {
            // Room is made from what is Done and longest past; a phone full of open work refuses.
            guard let victim = held.filter({ $0.clock?.isDone == true }).min(by: { $0.expiresAt < $1.expiresAt }) else {
                return .full
            }
            remove(id: victim.id)
        }
        guard writePhotos(opened) else { return .couldNotSave }
        held.append(HeldHandover(handover: incoming, receivedAt: at))
        save()
        PrivacyLog.store(.assistingHandovers, .recordWritten, slot: PrivacyToken("added"),
                         count: incoming.photos.count)
        return .added
    }

    // MARK: - The clock

    /// Take this job: start the expert's clock. Taking it twice changes nothing.
    func take(id: String) { mutate(id) { if $0.clock == nil { $0.clock = .take(at: now()) } } }
    func pause(id: String) { mutate(id) { $0.clock?.pause(at: now()) } }
    func resume(id: String) { mutate(id) { $0.clock?.resume(at: now()) } }
    func done(id: String) { mutate(id) { $0.clock?.done(at: now()) } }

    /// A sign of life for every running clock: called every minute while one runs and when the app
    /// leaves the foreground, so a kill loses at most the time since.
    func checkpointRunningClocks() {
        let at = now()
        var changed = false
        for index in held.indices where held[index].clock?.isRunning == true {
            held[index].clock?.checkpoint(at: at)
            changed = true
        }
        if changed { save() }
    }

    var hasRunningClock: Bool { held.contains { $0.clock?.isRunning == true } }

    /// The share of the time reply completed.
    func markReplySent(id: String) { mutate(id) { $0.replySentAt = now() } }

    private func recoverClocksAfterRelaunch() {
        let at = now()
        var recovered = 0
        for index in held.indices where held[index].clock?.isRunning == true {
            held[index].clock?.recoverAfterRelaunch(now: at)
            recovered += 1
        }
        if recovered > 0 {
            save()
            PrivacyLog.store(.assistingHandovers, .recovered, count: recovered)
        }
    }

    private func mutate(_ id: String, _ body: (inout HeldHandover) -> Void) {
        guard let index = held.firstIndex(where: { $0.id == id }) else { return }
        var copy = held[index]
        body(&copy)
        guard copy != held[index] else { return }
        held[index] = copy
        save()
    }

    // MARK: - Removing

    /// The expert's own delete, and the one retention and erasure use.
    func remove(id: String) {
        guard held.contains(where: { $0.id == id }) else { return }
        held.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: photoDirectory(handoverId: id))
        save()
    }

    /// Everything — what the registry's "delete all" column names.
    func removeAll() {
        let count = held.count
        held = []
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("photos", isDirectory: true))
        save()
        if count > 0 { PrivacyLog.store(.assistingHandovers, .cleared, count: count) }
    }

    /// Each handover's own retention (§7): removes every one past it. Returns how many went.
    @discardableResult
    func purgeExpired(now at: Date? = nil) -> Int {
        let instant = at ?? now()
        let doomed = held.filter { $0.isExpired(at: instant) }.map(\.id)
        doomed.forEach(remove(id:))
        return doomed.count
    }

    /// The subject erasure's call: every handover whose words mention `token` goes whole, photos
    /// and clock included — a handover is one organisation's job, and half of one is not kept.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let encoder = ExpertHandoverFile.encoder()
        let doomed = held.filter { entry in
            guard let data = try? encoder.encode(entry.handover) else { return false }
            return String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains(needle)
        }.map(\.id)
        doomed.forEach(remove(id:))
        return doomed.count
    }

    // MARK: - Storage

    /// Where the index lives, for the attribute-truth test.
    var fileLocation: URL { indexURL }

    private static func read(_ url: URL) -> [HeldHandover]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try ExpertHandoverFile.decoder().decode([HeldHandover].self, from: data)
        } catch {
            PrivacyLog.store(.assistingHandovers, .loadFailed, error: SafeErrorSummary(error))
            return nil
        }
    }

    private func save() {
        guard let data = try? ExpertHandoverFile.encoder().encode(held) else { return }
        do {
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            PrivacyLog.store(.assistingHandovers, .saveFailed, error: SafeErrorSummary(error))
        }
        protect(indexURL)
    }

    /// The folder a handover's photos live in, named by a digest of its id, so an id from a file
    /// can never name a path.
    private func photoDirectory(handoverId: String) -> URL {
        let digest = SHA256.hash(data: Data(handoverId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(32)), isDirectory: true)
    }

    private func photoURL(handoverId: String, index: Int) -> URL {
        photoDirectory(handoverId: handoverId).appendingPathComponent(String(format: "%02d.jpg", index + 1))
    }

    /// Replace a handover's photos with this generation's, by position.
    private func writePhotos(_ opened: ExpertHandoverFile.Opened) -> Bool {
        let folder = photoDirectory(handoverId: opened.handover.handoverId)
        try? FileManager.default.removeItem(at: folder)
        guard !opened.handover.photos.isEmpty else { return true }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, photo) in opened.handover.photos.enumerated() {
                guard let bytes = opened.photos[photo.file] else { continue }
                let url = photoURL(handoverId: opened.handover.handoverId, index: index)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            protect(directory)
            return true
        } catch {
            PrivacyLog.store(.assistingHandovers, .writeFailed, error: SafeErrorSummary(error))
            try? FileManager.default.removeItem(at: folder)
            return false
        }
    }

    /// First-unlock protection and no backup, on the folder and on what is in it: another
    /// organisation's job belongs on this phone for its retention period and nowhere a backup
    /// would carry it.
    private func protect(_ url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        try? manager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: url.path)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        if url == directory, let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator {
                try? manager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: child.path)
            }
        }
    }
}
