import Foundation

/// Where team-learning candidates live on the phone that filed them (Plan FP §1).
///
/// One JSON file in Application Support beside the delivery queue and the jobs ahead, loaded at
/// construction and written on every change. **Its own store, on purpose**: never the vault
/// overlay, whose core files are read straight into the next turn's prompt, and never
/// `DocumentStore`, which retrieval searches. A candidate is unreviewed text, and nothing that
/// builds a prompt or retrieves a passage reads this file — `team_learning list` reading the
/// author's own candidates back is the only reader.
///
/// Registered in `DataStoreRegistry` as `learningCandidates`. A finding is meant to name machines,
/// not people, but a customer's name is exactly what redaction cannot catch and review exists to
/// remove, so the store is treated as able to hold one: complete protection, excluded from backup,
/// and walked by the subject erasure.
@MainActor
final class LearningCandidateStore {

    static let shared = LearningCandidateStore()

    /// How many candidates a phone keeps. A crew member files a handful a week; a store that kept
    /// growing past this would be a notes app nobody reviews. Withdrawn candidates make room first.
    static let entryCap = 500

    private(set) var candidates: [LearningCandidate]

    private let fileURL: URL

    init(directory: URL? = nil) {
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("team-learning-candidates.json")
        candidates = Self.read(fileURL) ?? []
        protectFile()
    }

    // MARK: - Reading

    func candidate(id: String) -> LearningCandidate? { candidates.first { $0.id == id } }

    /// Newest first — the order `list` reads them back in, and the order "the last one" means.
    /// Times are whole seconds, so two filed in the same second fall back to the order they were
    /// filed in: "the last one" is the last one said, never whichever id sorts higher.
    var newestFirst: [LearningCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            lhs.element.createdAt == rhs.element.createdAt
                ? lhs.offset > rhs.offset
                : lhs.element.createdAt > rhs.element.createdAt
        }.map(\.element)
    }

    /// What a spoken handle names: a whole id, or a prefix of at least four characters that names
    /// exactly one candidate. An ambiguous prefix names nothing — guessing between two of them is
    /// how the wrong finding gets withdrawn.
    func resolve(handle: String) -> LearningCandidate? {
        let wanted = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "")
        guard !wanted.isEmpty else { return nil }
        if let exact = candidate(id: wanted) { return exact }
        guard wanted.count >= 4 else { return nil }
        let matches = candidates.filter { $0.id.hasPrefix(wanted) }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - Mutations

    func add(_ candidate: LearningCandidate) {
        var all = candidates.filter { $0.id != candidate.id } + [candidate]
        while all.count > Self.entryCap {
            let victim = all.filter(\.withdrawn).min { $0.createdAt < $1.createdAt }
                ?? all.min { $0.createdAt < $1.createdAt }
            guard let victim else { break }
            all.removeAll { $0.id == victim.id }
        }
        candidates = all
        save()
    }

    /// Replace a candidate in place.
    func update(_ candidate: LearningCandidate) {
        guard let index = candidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        candidates[index] = candidate
        save()
    }

    /// Everything, for a wipe — what the registry's "delete all" column names.
    func removeAll() {
        candidates = []
        save()
    }

    /// Remove every candidate whose words mention `token` — the subject erasure's call. Matched
    /// case-insensitively against the finding, symptom, fix, the spoken model and the author, the
    /// fields a person's name could be in. Returns how many went.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let doomed = candidates.filter { candidate in
            [candidate.finding, candidate.symptom ?? "", candidate.fix ?? "",
             candidate.spokenModel ?? "", candidate.author]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        guard !doomed.isEmpty else { return 0 }
        let ids = Set(doomed.map(\.id))
        candidates.removeAll { ids.contains($0.id) }
        save()
        return doomed.count
    }

    // MARK: - Storage

    private static func read(_ url: URL) -> [LearningCandidate]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([LearningCandidate].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(candidates) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        protectFile()
    }

    /// Complete protection and no backup: unreviewed findings that may yet carry a name review
    /// would have removed, which belong on this phone and nowhere a backup would carry them.
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
