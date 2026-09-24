import Foundation

/// Opens a job file handed to the app — "Open with OpenGlasses" from Mail, Files or Messages —
/// and puts it in front of the technician for review (Plan FO §8, P3c).
///
/// **Nothing is created without the tap.** Opening a file validates it, checks its signature
/// against the organisation's key and raises the review; only `accept` writes, and only into the
/// upcoming-jobs store. A job file never starts a job, never changes equipment, never creates a
/// task and never sends anything.
///
/// Files only: there is deliberately no `openglasses://job?…` link. A URL cannot carry a signed
/// document safely, and a link in an email that opens a job is the shape of a phishing message.
@MainActor
final class JobFileService: ObservableObject {

    enum Stage: Equatable {
        case idle
        case review(JobFileReview)
        case refused(String)
        /// Added, with the job's title — shown once, so the technician knows where it went.
        case added(String)
    }

    struct Seams {
        var store: () -> UpcomingJobStore? = { nil }
        var policy: () -> JobFileImportPolicy = { JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: false) }
        var organisationKey: () -> String = { "" }
        var organisationName: () -> String = { "" }
        var now: () -> Date = { Date() }
        /// Upcoming jobs live on the Job tab, which exists only while Field Assist is on.
        var fieldAssistActive: () -> Bool = { true }
    }

    static let fieldAssistOffMessage = "Field Assist is off on this phone, so a job file has nowhere to go. Turn it on under Settings → Field Assist, then open the file again."

    @Published private(set) var stage: Stage = .idle
    private var seams: Seams

    init(seams: Seams = Seams()) { self.seams = seams }

    func connect(_ seams: Seams) { self.seams = seams }

    /// Whether a URL handed to the app is a job file.
    static func isJobFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == JobFile.fileExtension
    }

    /// Read a file the system handed over, then let go of the system's copy.
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Refuse by size before reading, so a huge file is never pulled into memory.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= JobFile.maximumBytes else {
            stage = .refused(JobFileValidator.Refusal.tooLarge(size).message)
            Self.discardInboxCopy(url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            stage = .refused("The job file couldn't be read.")
            return
        }
        handle(data: data, fileName: url.lastPathComponent)
        Self.discardInboxCopy(url)
    }

    /// The pure half of `open`, for a file's bytes and name.
    func handle(data: Data, fileName: String) {
        guard seams.fieldAssistActive() else {
            stage = .refused(Self.fieldAssistOffMessage)
            return
        }
        let file: JobFile
        switch JobFileValidator.validate(data) {
        case .failure(let refusal):
            stage = .refused(refusal.message)
            return
        case .success(let valid):
            file = valid
        }
        let outcome = JobFileSignatureCheck.check(file, organisationKey: seams.organisationKey(),
                                                  organisationName: seams.organisationName())
        switch seams.policy().decide(outcome) {
        case .refuse(let message):
            stage = .refused(message)
        case .offer(let signature, let signer):
            let provenance = JobFileProvenance(fileName: fileName, signature: signature, signer: signer,
                                               receivedAt: seams.now(), digest: JobFile.digest(data))
            stage = .review(JobFileReview.make(file: file, provenance: provenance,
                                               existing: seams.store()?.jobs ?? [], now: seams.now()))
        }
    }

    /// The technician's answer. The only write in the whole path.
    @discardableResult
    func accept(_ decision: JobFileDecision) -> UpcomingJob? {
        guard case .review(let review) = stage, let store = seams.store() else { return nil }
        let written: UpcomingJob
        switch decision {
        case .update:
            guard let existing = review.duplicate else { return nil }
            // Same identity and place in the list; everything the file says replaces what was
            // there, including the brief, which described the job as it used to be.
            written = review.proposed.replacingIdentity(with: existing)
            store.update(written, at: seams.now())
        case .add, .keepBoth:
            written = review.proposed
            store.add(written)
        }
        stage = .added(written.title)
        return written
    }

    func dismiss() { stage = .idle }

    /// With `LSSupportsOpeningDocumentsInPlace` off, the system copies the file into
    /// `Documents/Inbox` before handing it over. The job ahead is what is kept; the copy is not.
    private static func discardInboxCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

extension UpcomingJob {
    /// This job's contents under another job's identity — what "Update job 1007" writes.
    func replacingIdentity(with existing: UpcomingJob) -> UpcomingJob {
        UpcomingJob(id: existing.id, jobReference: jobReference, site: site, faultReport: faultReport,
                    equipment: equipment, scheduledFor: scheduledFor, notes: notes,
                    attachments: attachments, origin: origin, provenance: provenance,
                    brief: nil, createdAt: existing.createdAt)
    }
}
