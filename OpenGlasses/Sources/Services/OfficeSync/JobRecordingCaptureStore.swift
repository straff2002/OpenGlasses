import Foundation

/// A job being recorded, on the phone, before it is sealed for the office (Plan HE §1).
///
/// The recorder writes each part straight into the job's own folder — never the temporary
/// directory, the Recordings folder or Photos:
///
/// ```
/// <job>/recording/capture/
///   <partID>.mp4      one recorded part: the glasses' pictures and the microphone's sound, unblurred
///   journal.json      the recording so far: its clock, its parts, what was noted as it happened
/// ```
///
/// The folder is made `completeUnlessOpen` and kept out of backup before anything is written to
/// it, so a part is protected while it is being written and not only once it is finished. It lasts
/// as long as the recording does: sealing cuts the parts into the bundle
/// (`JobRecordingBundleStore`) and this folder is removed. It goes with its job.
///
/// The journal is what lets a recording survive the app being closed in the middle of it: the
/// parts that had finished, and when, are known, so they can be sealed. It holds times, part
/// names and tool names — no words.
///
/// **This type offers no way off the phone.** It reads sizes, writes the journal and deletes. The
/// only exit a recorded job has is the bundle.
struct JobRecordingCaptureStore: Sendable {

    /// Something noted as it happened, on the session clock.
    struct Noted: Codable, Equatable, Sendable {
        let t: SessionTime
        /// `SessionTimeline.EventKind`'s spelling.
        let kind: String
        var ref: String?

        init(t: SessionTime, kind: SessionTimeline.EventKind, ref: String? = nil) {
            self.t = t
            self.kind = kind.rawValue
            self.ref = ref
        }

        /// The event as the timeline records it, or nil for a kind this version does not know.
        var event: SessionTimeline.Event? {
            SessionTimeline.EventKind(rawValue: kind).map { .init(t: t, kind: $0, ref: ref) }
        }
    }

    struct Journal: Codable, Equatable, Sendable {
        let sessionID: String
        var jobNumber: String?
        /// The session's zero as a wall time. The monotonic reading taken with it is not kept: it
        /// means nothing after the phone restarts.
        let wallStart: Date
        /// When the person recording acknowledged the consent. It goes into the manifest.
        let consentAt: Date
        /// Every part that finished, placed on the session clock.
        var parts: [RecordingTimebase.PlacedPart] = []
        var noted: [Noted] = []
        /// How many parts have been begun, finished or not: the next part's number.
        var partsBegun = 0
        /// When the recording stopped, on the session clock. Nil while it is still running — or
        /// was, when the app closed.
        var stoppedAt: SessionTime?

        var isStopped: Bool { stoppedAt != nil }
    }

    enum Failure: Error, Equatable {
        /// The session identifier is not one a path may be built from.
        case notAnIdentifier
    }

    /// The folder every job's own folder is in.
    let sessionsRoot: URL

    // MARK: - Where things are

    func directory(sessionID: String) -> URL {
        sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("recording", isDirectory: true)
            .appendingPathComponent("capture", isDirectory: true)
    }

    func partFile(sessionID: String, partID: String) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("\(partID).mp4")
    }

    private func journalFile(sessionID: String) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("journal.json")
    }

    // MARK: - Making the folder

    /// Makes the folder a recording is written into: protected, and out of backup, before the
    /// recorder creates anything in it. A file made in a protected folder takes its protection.
    func prepare(sessionID: String) throws {
        guard JobRecordingBundleStore.identifier(sessionID) else { throw Failure.notAnIdentifier }
        var folder = directory(sessionID: sessionID)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
        // A folder that was already there keeps whatever it had, so it is set again.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                               ofItemAtPath: folder.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Sets a finished part's protection by name as well: the folder's is inherited, and this does
    /// not rely on it.
    func protect(partAt file: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen],
                                               ofItemAtPath: file.path)
    }

    // MARK: - The journal

    func save(_ journal: Journal) throws {
        guard JobRecordingBundleStore.identifier(journal.sessionID) else { throw Failure.notAnIdentifier }
        try JSONEncoder().encode(journal).write(to: journalFile(sessionID: journal.sessionID),
                                               options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func journal(sessionID: String) -> Journal? {
        guard JobRecordingBundleStore.identifier(sessionID),
              let data = try? Data(contentsOf: journalFile(sessionID: sessionID)),
              let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.sessionID == sessionID else { return nil }
        return journal
    }

    /// Whether a journal is on disk for this job, readable or not. A journal that is there and
    /// cannot be read — the phone is locked, or the file is damaged — is still a recording, and
    /// must not be mistaken for none.
    func hasJournal(sessionID: String) -> Bool {
        JobRecordingBundleStore.identifier(sessionID)
            && FileManager.default.fileExists(atPath: journalFile(sessionID: sessionID).path)
    }

    /// Every recording on this phone that has not been sealed, oldest first.
    func journals() -> [Journal] {
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        return sessions.compactMap(journal(sessionID:)).sorted { ($0.wallStart, $0.sessionID) < ($1.wallStart, $1.sessionID) }
    }

    // MARK: - Sizes

    /// The bytes one job's unsealed recording holds: its parts, including the one being written.
    func bytes(sessionID: String) -> Int64 {
        let folder = directory(sessionID: sessionID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".mp4") }.reduce(0) { total, name in
            total + Self.size(of: folder.appendingPathComponent(name))
        }
    }

    /// The bytes every unsealed recording holds. None of it has been acknowledged by anybody.
    func totalBytes() -> Int64 {
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        return sessions.filter(JobRecordingBundleStore.identifier).reduce(0) { $0 + bytes(sessionID: $1) }
    }

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Removing

    /// Removes one part's file: a part that recorded nothing, or one that was never finished and
    /// so cannot be played.
    func removePart(sessionID: String, partID: String) {
        try? FileManager.default.removeItem(at: partFile(sessionID: sessionID, partID: partID))
    }

    /// Removes the part files the journal does not list as finished. After the app was closed
    /// mid-recording, the part it was writing is one of them: it has no index and does not play.
    func removeUnfinishedParts(_ journal: Journal) {
        let folder = directory(sessionID: journal.sessionID)
        let finished = Set(journal.parts.map { "\($0.partID).mp4" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasSuffix(".mp4") && !finished.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Removes a job's unsealed recording: its parts and its journal.
    func remove(sessionID: String) {
        guard JobRecordingBundleStore.identifier(sessionID) else { return }
        try? FileManager.default.removeItem(at: directory(sessionID: sessionID))
    }
}
