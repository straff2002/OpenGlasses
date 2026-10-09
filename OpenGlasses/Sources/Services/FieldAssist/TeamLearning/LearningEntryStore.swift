import Foundation

/// Where approved team learnings live on a phone (Plan FP P2): the live entries that answer, and
/// the superseded and retracted ones kept as history.
///
/// One JSON file in Application Support beside the candidate store, loaded at construction and
/// written on every change. **It is the record, not the retrieval index**: what answers a question
/// is the entry's document in `DocumentStore` under `learning:<vaultId>` (`LearningCorpus`), and
/// a superseded or retracted entry stays here — the organisation keeps what it once believed,
/// which is an auditor's question — while its document leaves the namespace.
///
/// Registered in `DataStoreRegistry` as `learningEntries`. An approved entry has been read by a
/// reviewer whose job includes removing a customer's name, but a slip is still possible, so the
/// store is treated as able to hold one: complete protection, excluded from backup, walked by the
/// subject erasure, and cleared when the phone leaves its organisation.
@MainActor
final class LearningEntryStore {

    static let shared = LearningEntryStore()

    private(set) var entries: [LearningEntry]

    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("team-learning-entries.json")
        entries = Self.read(fileURL) ?? []
        protectFile()
    }

    // MARK: - Reading

    func entry(id: String) -> LearningEntry? { entries.first { $0.id == id } }

    /// The entries that answer: neither superseded nor retracted.
    var live: [LearningEntry] { entries.filter(\.isLive) }

    /// The entry a corpus document id names (`LearningCorpus.documentId(entryID:vaultId:)`).
    func entry(forDocumentId documentId: String) -> LearningEntry? {
        LearningCorpus.entryID(fromDocumentId: documentId).flatMap(entry(id:))
    }

    // MARK: - Mutations

    /// Add or replace an entry by id.
    func upsert(_ entry: LearningEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// Everything, for a wipe — what the registry's "delete all" column names.
    func removeAll() {
        entries = []
        save()
    }

    /// Remove every entry whose words mention `token` — the subject erasure's call. Matched
    /// case-insensitively against the finding, symptom, fix, the text as captured, the subject and
    /// the approver, the fields a person's name could be in. Returns how many went.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let doomed = entries.filter { entry in
            [entry.finding, entry.symptom ?? "", entry.fix ?? "",
             entry.captured?.finding ?? "", entry.captured?.symptom ?? "", entry.captured?.fix ?? "",
             entry.subject.citationSubject, entry.approvedByName, entry.approvedByRole,
             entry.retractionReason ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        guard !doomed.isEmpty else { return 0 }
        let ids = Set(doomed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        save()
        return doomed.count
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [LearningEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LearningEntry].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        protectFile()
    }

    /// Complete protection and no backup: a restored copy would put an organisation's approved
    /// findings — and anything review missed — onto a phone that may no longer belong to it.
    private func protectFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Where the file is, for the attribute-truth test.
    var fileLocation: URL { fileURL }
}
