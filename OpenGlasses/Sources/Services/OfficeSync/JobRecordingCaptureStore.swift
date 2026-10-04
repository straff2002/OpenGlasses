import Foundation

/// A job being recorded, on the phone, before it is sealed for the office (Plan HE §1).
///
/// The recorder writes each part straight into the job's own folder — never the temporary
/// directory, the Recordings folder or Photos:
///
/// ```
/// <job>/recording/capture/
///   <partID>.mp4            one recorded part: the glasses' pictures and the microphone's sound, unblurred
///   <partID>.blurred.mp4    the same part with every picture through the face blur, where the
///                           organisation requires it — finished, checked and written down in the journal
///   <partID>.blurring.mp4   that blurred part while it is being made; never a part of anything
///   journal.json            the recording so far: its clock, its parts, what was noted as it happened
/// ```
///
/// **A name says what a file is, and is never reused.** `<partID>.mp4` is only ever what the
/// recorder wrote, unblurred. `<partID>.blurred.mp4` is only ever the output of a blur pass that
/// finished — and it counts as the part only once the journal says so (`Journal.blurred`): one
/// that is there without its line in the journal is removed and made again. `<partID>.blurring.mp4`
/// is removed wherever it is found. So an interrupted pass leaves the unblurred part where it was
/// and nothing that could be taken for a blurred one.
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
        /// Whether faces must be blurred before this recording is sealed: the organisation
        /// required it at some moment between the recording starting and its being prepared.
        /// Once set it stays set — what was recorded under the rule is blurred, whatever the
        /// rule says later.
        var blurRequired: Bool?
        /// What the blur pass did to each part it has finished and that has been checked. A part
        /// named here is the blurred file; a part not named here has not been blurred.
        var blurred: [BlurredPart]?

        var isStopped: Bool { stoppedAt != nil }
        var mustBeBlurred: Bool { blurRequired == true }

        func blurredPart(_ partID: String) -> BlurredPart? { blurred?.first { $0.partID == partID } }
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

    /// A part once every picture in it has been through the face blur. It is the part only when
    /// the journal says so.
    func blurredPartFile(sessionID: String, partID: String) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("\(partID).blurred.mp4")
    }

    /// Where a blurred part is written while it is being made.
    func blurScratchFile(sessionID: String, partID: String) -> URL {
        directory(sessionID: sessionID).appendingPathComponent("\(partID).blurring.mp4")
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

    /// The jobs that have a recording on this phone that has not been sealed, readable or not, in
    /// a fixed order.
    func sessionIDsWithJournal() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? [])
            .filter(hasJournal(sessionID:)).sorted()
    }

    /// Every recording on this phone that has not been sealed, oldest first.
    func journals() -> [Journal] {
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot.path)) ?? []
        return sessions.compactMap(journal(sessionID:)).sorted { ($0.wallStart, $0.sessionID) < ($1.wallStart, $1.sessionID) }
    }

    // MARK: - Sizes

    /// The bytes one job's unsealed recording holds: its parts, including the one being written
    /// and a blurred part and the unblurred one it is replacing, while both are there.
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
        // A finished part's own file, and its blurred replacement once the journal names it.
        let finished = Set(journal.parts.map { "\($0.partID).mp4" })
            .union((journal.blurred ?? []).map { "\($0.partID).blurred.mp4" })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasSuffix(".mp4") && !finished.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Removes anything a blur pass left half made. Safe at any time: a file being made is never
    /// a part.
    func removeBlurScratch(sessionID: String) {
        let folder = directory(sessionID: sessionID)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasSuffix(".blurring.mp4") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Whether any unblurred part is still in the folder: any `.mp4` that is neither a blurred
    /// part nor one being made. Asked before a bundle is sealed as blurred.
    func holdsUnblurredParts(sessionID: String) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(sessionID: sessionID).path)) ?? []
        return names.contains { $0.hasSuffix(".mp4") && !$0.hasSuffix(".blurred.mp4") && !$0.hasSuffix(".blurring.mp4") }
    }

    /// Removes a job's unsealed recording: its parts and its journal.
    func remove(sessionID: String) {
        guard JobRecordingBundleStore.identifier(sessionID) else { return }
        try? FileManager.default.removeItem(at: directory(sessionID: sessionID))
    }

    /// Removes a job's unsealed recording because the technician deleted it: its parts and its
    /// journal, and the folder they were in when nothing else is in it. A sealed bundle beside
    /// them is not touched, and neither is anything else of the job.
    func delete(sessionID: String) {
        guard JobRecordingBundleStore.identifier(sessionID) else { return }
        remove(sessionID: sessionID)
        let recording = directory(sessionID: sessionID).deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: recording.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: recording)
        }
    }
}
