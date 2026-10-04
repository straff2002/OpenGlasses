import CryptoKit
import Foundation

/// The attachments that follow a job from the office (Contracts/office-bulk.md §5).
///
/// A format-2 job may name an attachment by its exact digest, size and type. That is the only
/// thing that makes this phone take one: an attachment is asked of the office's `bulk` folder
/// because a signed job this phone holds names its bytes, and it is kept only once its size and
/// digest have been checked again here. It is opened as untrusted content of the type the job
/// stated, and it is never sent anywhere.
///
/// An attachment belongs to its job. It is kept while a job that names it is ahead or open on
/// this phone, and removed on the next pass after that job is removed or finished.
///
/// It does not talk to the folder about what to take: `OfficeManualService` is the one owner of
/// that list, and asks for `wanted` alongside the archives it wants itself.
@MainActor
final class OfficeJobAttachmentStore: ObservableObject {

    enum State: Equatable, Sendable {
        /// On this phone, checked, at this file.
        case ready(URL)
        case downloading
        /// The office has it and the route is one large content does not use unasked.
        case waitingForWiFi
        /// The office has not put it in the folder yet, or this phone is not connected to it.
        case waitingForOffice
        case notEnoughSpace
        /// Larger than this phone takes as a job attachment.
        case tooLarge
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The attachments named by the signed jobs this phone holds: ahead, and started but not
        /// finished.
        var named: @MainActor () -> [JobNeeds.Attachment] = { [] }
        var directory: URL
        /// Free space on the volume the attachments are kept on, when the system will say.
        var freeBytes: () -> Int64? = { nil }
        /// This phone's ceiling on one attachment, which no job can raise.
        var maximumBytes: Int64 = 50 * 1_048_576
    }

    /// Space left alone beyond the file itself, so taking an attachment never fills the phone.
    static let spaceMargin: Int64 = 100 * 1_048_576

    /// Where each attachment a held job names is, by digest.
    @Published private(set) var states: [String: State] = [:]

    private let seams: Seams

    init(seams: Seams) {
        self.seams = seams
        refresh(status: [:], allowed: false)
    }

    // MARK: - What to ask the folder for

    /// The attachments still to come: named by a held job, not here yet, and ones this phone has
    /// room for. Nothing else is ever asked of the folder for a job.
    var wanted: [JobNeeds.Attachment] {
        let free = seams.freeBytes()
        return named().filter { attachment in
            stored(attachment) == nil && attachment.bytes <= seams.maximumBytes
                && Self.fits(attachment.bytes, free: free)
        }
    }

    /// After the folder has said where each wanted attachment is: take the ones that have
    /// arrived, let go of the ones no held job names any more, and say where the rest are.
    func took(status: [String: String], allowed: Bool) async {
        for attachment in named() where status[attachment.sha256] == "ready" && stored(attachment) == nil {
            guard let path = try? await seams.transport.bulkFile(sha256: attachment.sha256) else { continue }
            keep(URL(fileURLWithPath: path), as: attachment)
        }
        prune()
        refresh(status: status, allowed: allowed)
    }

    /// Where one attachment is. An attachment no pass has looked at yet is waiting for the office.
    func state(of attachment: JobNeeds.Attachment) -> State {
        if let file = stored(attachment) { return .ready(file) }
        return states[attachment.sha256] ?? .waitingForOffice
    }

    /// Everything kept, for leaving the organisation or erasing the phone's job content.
    func removeAll() {
        try? FileManager.default.removeItem(at: seams.directory)
        refresh(status: [:], allowed: false)
    }

    // MARK: - Keeping

    /// Copies what the folder took into the store, only as exactly the bytes the job named.
    private func keep(_ source: URL, as attachment: JobNeeds.Attachment) {
        guard let file = Self.file(for: attachment, in: seams.directory),
              Self.size(of: source) == attachment.bytes,
              Self.digest(of: source) == attachment.sha256 else { return }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: seams.directory, withIntermediateDirectories: true)
            var directory = seams.directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            try? manager.removeItem(at: file)
            try manager.copyItem(at: source, to: file)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path)
        } catch {
            try? manager.removeItem(at: file)
        }
    }

    /// The file for an attachment, when it is here as exactly the size the job named.
    private func stored(_ attachment: JobNeeds.Attachment) -> URL? {
        guard let file = Self.file(for: attachment, in: seams.directory),
              Self.size(of: file) == attachment.bytes else { return nil }
        return file
    }

    /// Removes every kept file no held job names now.
    private func prune() {
        let keep = Set(named().compactMap { Self.file(for: $0, in: seams.directory)?.lastPathComponent })
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: seams.directory.path)) ?? []
        for name in kept where !keep.contains(name) {
            try? FileManager.default.removeItem(at: seams.directory.appendingPathComponent(name))
        }
    }

    private func refresh(status: [String: String], allowed: Bool) {
        let free = seams.freeBytes()
        var next: [String: State] = [:]
        for attachment in named() {
            if let file = stored(attachment) {
                next[attachment.sha256] = .ready(file)
            } else if attachment.bytes > seams.maximumBytes {
                next[attachment.sha256] = .tooLarge
            } else if !Self.fits(attachment.bytes, free: free) {
                next[attachment.sha256] = .notEnoughSpace
            } else {
                switch status[attachment.sha256] {
                case "offered": next[attachment.sha256] = allowed ? .downloading : .waitingForWiFi
                // Taken by the folder and not kept: it is taken again on the next pass.
                case "ready": next[attachment.sha256] = .downloading
                default: next[attachment.sha256] = .waitingForOffice
                }
            }
        }
        if next != states { states = next }
    }

    /// The attachments the store answers for, one per digest, and only ones it could keep a file
    /// for.
    private func named() -> [JobNeeds.Attachment] {
        var seen = Set<String>()
        return seams.named().filter { Self.file(for: $0, in: seams.directory) != nil && seen.insert($0.sha256).inserted }
    }

    // MARK: - Pure

    /// The attachments the jobs held name, for jobs whose file was signed by the organisation. A
    /// job that is only a claim is shown, and fetches nothing.
    static func named(_ jobs: [(needs: JobNeeds?, provenance: JobFileProvenance?)]) -> [JobNeeds.Attachment] {
        jobs.flatMap { job -> [JobNeeds.Attachment] in
            guard job.provenance?.signature == .signed else { return [] }
            return job.needs?.attachments ?? []
        }
    }

    static func fits(_ bytes: Int64, free: Int64?) -> Bool {
        guard let free else { return true }
        return free - spaceMargin >= bytes
    }

    /// Where an attachment is kept: its digest and the extension of the type the job stated. Nil
    /// for a digest or a type outside the contract, so nothing of the job's own words is ever a
    /// path.
    static func file(for attachment: JobNeeds.Attachment, in directory: URL) -> URL? {
        guard attachment.sha256.utf8.count == 64,
              attachment.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              attachment.bytes > 0,
              let ext = JobFile.attachmentMediaTypes[attachment.mediaType] else { return nil }
        return directory.appendingPathComponent("\(attachment.sha256).\(ext)")
    }

    nonisolated static func size(of file: URL) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    /// The file's SHA-256, read in pieces so a large attachment is never held in memory whole.
    nonisolated static func digest(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The words for one attachment. "Ready" only once the file is on this phone and checked.
    static func status(_ attachment: JobNeeds.Attachment, state: State) -> OfficeFieldConnectionPolicy.Status {
        let size = ByteCountFormatter.string(fromByteCount: attachment.bytes, countStyle: .file)
        switch state {
        case .ready:
            return .init(title: attachment.name, detail: "Ready. \(size).", systemImage: "doc")
        case .downloading:
            return .init(title: attachment.name, detail: "Still downloading. \(size).", systemImage: "arrow.down.circle")
        case .waitingForWiFi:
            return .init(title: attachment.name, detail: "Waiting for Wi-Fi. \(size).", systemImage: "wifi.exclamationmark")
        case .waitingForOffice:
            return .init(title: attachment.name, detail: "Waiting for the office to send it. \(size).", systemImage: "clock")
        case .notEnoughSpace:
            return .init(title: attachment.name, detail: "Not enough space on this phone. \(size).",
                         systemImage: "externaldrive.badge.exclamationmark")
        case .tooLarge:
            return .init(title: attachment.name, detail: "Too large to keep on this phone. \(size).",
                         systemImage: "exclamationmark.triangle")
        }
    }

    /// The words for a manual set a job names.
    static func status(set setID: String, standing: OfficeManualService.SetStanding?) -> OfficeFieldConnectionPolicy.Status {
        switch standing {
        case .ready?:
            return .init(title: "Manual \(setID)", detail: "Ready.", systemImage: "checkmark.circle")
        case .onItsWay?:
            return .init(title: "Manual \(setID)", detail: "On its way from the office.", systemImage: "arrow.down.circle")
        case .notYetAvailable?, nil:
            return .init(title: "Manual \(setID)", detail: "Not yet available.", systemImage: "clock")
        }
    }
}

extension OfficeJobAttachmentStore {
    nonisolated static func defaultDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("job-attachments", isDirectory: true)
    }

    nonisolated static func volumeFreeBytes(_ directory: URL) -> Int64? {
        let values = try? directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
