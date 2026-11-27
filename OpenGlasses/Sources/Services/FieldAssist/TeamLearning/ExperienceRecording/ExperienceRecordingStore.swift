import Foundation

/// Where experience recordings live on the phone that made them (Plan IM P1).
///
/// One JSON index beside the team-learning candidates, and one folder of audio files named by
/// recording id. **Its own store, on purpose**, as the candidates' is: a recording is unreviewed
/// speech, and nothing that builds a prompt or retrieves a passage reads it. The recorder's own
/// list is the only reader in P1, and nothing leaves the phone (P3 is what sends one).
///
/// Registered in `DataStoreRegistry` as `experienceRecordings`. The recorder asks for no customer
/// names or addresses, but a recording of someone talking about their work is exactly where one
/// slips out, so the store is treated as able to hold a third party: first-unlock protection
/// (recordings are made from the car with the phone locked), excluded from backup, walked by the
/// subject erasure, and cleared when the phone leaves its organisation. The audio goes 30 days
/// after it was recorded (decision 2) — swept when the store opens and whenever the app asks.
@MainActor
final class ExperienceRecordingStore: ObservableObject {

    static let shared = ExperienceRecordingStore()

    /// The protection class this store's files are written with and re-stamped to. First-unlock,
    /// not `.complete`, for the reason every voice-written store uses it: a recording finished on
    /// CarPlay is saved with the phone locked in a pocket.
    nonisolated static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication

    @Published private(set) var recordings: [ExperienceRecording]

    private let fileURL: URL
    private let audioFolder: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default, now: Date = Date()) {
        self.fileManager = fileManager
        let folder = directory ?? DeliveryQueueStore.defaultDirectory()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("experience-recordings.json")
        audioFolder = folder.appendingPathComponent("ExperienceRecordings", isDirectory: true)
        recordings = Self.read(fileURL) ?? []
        protect(fileURL)
        sweepExpiredAudio(now: now)
    }

    // MARK: - Reading

    func recording(id: String) -> ExperienceRecording? { recordings.first { $0.id == id } }

    /// Newest first: the order the recorder's list shows them in.
    var newestFirst: [ExperienceRecording] {
        recordings.enumerated().sorted { lhs, rhs in
            lhs.element.createdAt == rhs.element.createdAt
                ? lhs.offset > rhs.offset
                : lhs.element.createdAt > rhs.element.createdAt
        }.map(\.element)
    }

    /// Where a recording's audio is kept, whether or not it is there.
    func audioURL(for id: String) -> URL {
        audioFolder.appendingPathComponent("\(id).m4a")
    }

    /// Whether the recording's audio is still on the phone.
    func hasAudio(_ id: String) -> Bool {
        fileManager.fileExists(atPath: audioURL(for: id).path)
    }

    // MARK: - Mutations

    /// Keep a recording, moving its audio in from wherever the recorder wrote it. A recording
    /// whose audio could not be moved is still kept — the transcript is the record — and says so
    /// by carrying no audio.
    func add(_ recording: ExperienceRecording, audioFrom source: URL? = nil) {
        if let source { moveAudio(from: source, for: recording.id) }
        var all = recordings.filter { $0.id != recording.id } + [recording]
        while all.count > ExperienceRecorderRules.entryCap {
            let victim = all.filter { $0.status == .reviewed }.min { $0.createdAt < $1.createdAt }
                ?? all.min { $0.createdAt < $1.createdAt }
            guard let victim else { break }
            removeAudio(victim.id)
            all.removeAll { $0.id == victim.id }
        }
        recordings = all
        save()
    }

    /// Move a recording on: `recorded → sent → drafted → reviewed`, forward only. Returns false,
    /// and changes nothing, for a step backwards, a repeat, or an id this phone does not hold.
    @discardableResult
    func advance(id: String, to status: ExperienceRecording.Status) -> Bool {
        guard let index = recordings.firstIndex(where: { $0.id == id }),
              recordings[index].status.canAdvance(to: status) else { return false }
        recordings[index].status = status
        save()
        return true
    }

    /// Delete one recording and its audio — the technician's own choice on the list.
    func delete(id: String) {
        guard recordings.contains(where: { $0.id == id }) else { return }
        removeAudio(id)
        recordings.removeAll { $0.id == id }
        save()
    }

    /// Everything, audio included — what the registry's "delete all" column names, and what
    /// leaving the organisation runs.
    func removeAll() {
        recordings = []
        save()
        try? fileManager.removeItem(at: audioFolder)
    }

    /// Remove every recording whose words mention `token`, with its audio — the subject erasure's
    /// call. Matched case-insensitively against the transcript, the spoken model and the site,
    /// the fields a person's name could be in. Returns how many went.
    @discardableResult
    func deleteMatching(_ token: String) -> Int {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let doomed = recordings.filter { recording in
            [recording.transcript, recording.spokenModel ?? "", recording.site ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        guard !doomed.isEmpty else { return 0 }
        let ids = Set(doomed.map(\.id))
        for id in ids { removeAudio(id) }
        recordings.removeAll { ids.contains($0.id) }
        save()
        return doomed.count
    }

    /// Delete the audio of every recording made more than 30 days before `now` (decision 2). The
    /// transcript stays — it is what the reviewer reads — and the recording says when its audio
    /// went. Audio files no recording names are removed too. Returns how many files went.
    @discardableResult
    func sweepExpiredAudio(now: Date = Date()) -> Int {
        var removed = 0
        var changed = false
        let cutoff = now.addingTimeInterval(-ExperienceRecorderRules.audioRetention)
        for index in recordings.indices where recordings[index].createdAt <= cutoff
            && recordings[index].audioDeletedAt == nil {
            if hasAudio(recordings[index].id) {
                removeAudio(recordings[index].id)
                removed += 1
            }
            recordings[index].audioDeletedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            changed = true
        }
        let named = Set(recordings.map { "\($0.id).m4a" })
        let present = (try? fileManager.contentsOfDirectory(atPath: audioFolder.path)) ?? []
        for file in present where !named.contains(file) {
            try? fileManager.removeItem(at: audioFolder.appendingPathComponent(file))
            removed += 1
        }
        if changed { save() }
        return removed
    }

    // MARK: - Storage

    private func moveAudio(from source: URL, for id: String) {
        try? fileManager.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        protect(audioFolder)
        let destination = audioURL(for: id)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: source)
            return
        }
        protect(destination)
    }

    private func removeAudio(_ id: String) {
        try? fileManager.removeItem(at: audioURL(for: id))
    }

    private static func read(_ url: URL) -> [ExperienceRecording]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([ExperienceRecording].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recordings) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        protect(fileURL)
    }

    /// First-unlock protection and no backup, on the index, the audio folder and each file in it:
    /// unreviewed speech that may hold a name review would have removed belongs on this phone and
    /// nowhere a backup would carry it.
    private func protect(_ target: URL) {
        guard fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: target.path)
        var url = target
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Where the index is, for the attribute-truth test.
    var fileLocation: URL { fileURL }
    /// Where the audio is, for the attribute-truth test.
    var audioLocation: URL { audioFolder }
}
