import Foundation

/// Add-ons the assistant built and tested that the wearer has not yet approved, with each one's
/// test trace — and the record of when building sessions started, for the daily limit.
///
/// Under `Documents/addon-drafts/`: `drafts.json` (the drafts) and `starts.json` (session start
/// times, the last two days only), both through `JSONStore`'s salvage semantics, with first-unlock
/// protection (a session can finish while the phone is locked) and excluded from backup.
///
/// A draft lives until the wearer approves it (it moves to `AddOnStore` and is deleted here), turns
/// it down, or 24 hours pass after its test; nothing here is ever installed or run as a skill.
@MainActor
final class AddOnDraftStore: ObservableObject {

    struct Draft: Codable, Equatable, Identifiable, Sendable {
        /// The building session's id.
        let id: String
        /// What the wearer asked for, in their words.
        let goal: String
        let addOnID: String
        let name: String
        let version: String
        /// An improvement to an installed add-on rather than a new one.
        let isUpdate: Bool
        /// The exact file that was tested.
        let fileBytes: Data
        let sampleQuestion: String
        let trace: DryRunTrace
        let createdAt: Date
        let testedAt: Date

        var expiresAt: Date { testedAt.addingTimeInterval(AddOnAuthoringSession.draftLifetime) }
    }

    @Published private(set) var drafts: [Draft] = []

    private let directory: URL
    private let draftsURL: URL
    private let startsURL: URL
    private let backupDirectory: URL?
    private var starts: [Date] = []
    private var savingAllowed = true

    static let folderName = "addon-drafts"

    init(directory: URL? = nil, backupDirectory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? docs.appendingPathComponent(Self.folderName, isDirectory: true)
        draftsURL = self.directory.appendingPathComponent("drafts.json")
        startsURL = self.directory.appendingPathComponent("starts.json")
        self.backupDirectory = backupDirectory
        load()
    }

    var isWritable: Bool { savingAllowed }

    func draft(id: String) -> Draft? { drafts.first { $0.id == id } }

    /// Keep a tested draft until the wearer decides (replacing one with the same session id).
    func save(_ draft: Draft) {
        guard savingAllowed else { return }
        drafts.removeAll { $0.id == draft.id }
        drafts.append(draft)
        persistDrafts()
    }

    /// Delete one draft and its trace.
    func remove(id: String) {
        guard savingAllowed, drafts.contains(where: { $0.id == id }) else { return }
        drafts.removeAll { $0.id == id }
        persistDrafts()
    }

    /// Delete every draft past its 24 hours. Returns how many went.
    @discardableResult
    func sweepExpired(now: Date) -> Int {
        guard savingAllowed else { return 0 }
        let before = drafts.count
        drafts.removeAll { now >= $0.expiresAt }
        let removed = before - drafts.count
        if removed > 0 { persistDrafts() }
        return removed
    }

    /// Everything: every draft, every trace and the session record.
    @discardableResult
    func deleteAll() -> Bool {
        drafts = []
        starts = []
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            return true
        } catch {
            PrivacyLog.store(.addOns, .writeFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    // MARK: - Sessions per day

    func sessionStarts() -> [Date] { starts }

    func recordSessionStart(at date: Date) {
        guard savingAllowed else { return }
        starts = (starts + [date]).filter { date.timeIntervalSince($0) < 2 * 24 * 60 * 60 }
        write(starts, to: startsURL)
    }

    // MARK: - Private

    private func load() {
        switch JSONStore.loadArray(Draft.self, at: draftsURL, name: "addon_drafts", backupDirectory: backupDirectory) {
        case .loaded(let rows), .recovered(let rows, _): drafts = rows
        case .absent, .corrupt: drafts = []
        case .unreadable:
            drafts = []
            savingAllowed = false
        }
        switch JSONStore.loadArray(Date.self, at: startsURL, name: "addon_draft_starts", backupDirectory: backupDirectory) {
        case .loaded(let rows), .recovered(let rows, _): starts = rows
        case .absent, .corrupt: starts = []
        case .unreadable:
            starts = []
            savingAllowed = false
        }
    }

    private func persistDrafts() { write(drafts, to: draftsURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard savingAllowed else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true, to: url)
        } catch {
            PrivacyLog.store(.addOns, .saveFailed, error: SafeErrorSummary(error))
        }
    }
}
