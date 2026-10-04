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
        /// This exact job is already on this phone: the same office job at the same revision.
        /// Nothing to review and nothing added.
        case alreadyHeld(String)
    }

    struct Seams {
        var store: () -> UpcomingJobStore? = { nil }
        var policy: () -> JobFileImportPolicy = { JobFileImportPolicy.resolve(medicalMode: false, organisationRequiresSigned: false) }
        var organisationKey: () -> String = { "" }
        var organisationName: () -> String = { "" }
        var now: () -> Date = { Date() }
        /// Upcoming jobs live on the Job tab, which exists only while Field Assist is on.
        var fieldAssistActive: () -> Bool = { true }
        /// The job files of jobs already started on this phone, so a file for one of them is not
        /// offered as a new job.
        var startedJobFiles: () -> [JobFileProvenance] = { [] }
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
        switch assess(data) {
        case .refuse(let message):
            stage = .refused(message)
        case .held(let title):
            stage = .alreadyHeld(title)
        case .offer(let file, let signature, let signer, let revises):
            let provenance = JobFileProvenance(fileName: fileName, signature: signature, signer: signer,
                                               receivedAt: seams.now(), digest: JobFile.digest(data),
                                               identity: file.identity)
            stage = .review(JobFileReview.make(file: file, provenance: provenance,
                                               existing: seams.store()?.jobs ?? [], revises: revises,
                                               now: seams.now()))
        }
    }

    /// Why `handle` would refuse these bytes now, or nil when it would not. Raises nothing and
    /// changes nothing: for a caller that has to know before it offers a file.
    func refusal(for data: Data) -> String? {
        if case .refuse(let message) = assess(data) { return message }
        return nil
    }

    /// Whether these bytes are a job this phone already has: the same office job at the same
    /// revision, ahead or already started. There is nothing to review and nothing to add.
    func isAlreadyHeld(_ data: Data) -> Bool {
        if case .held = assess(data) { return true }
        return false
    }

    private enum Assessment {
        case refuse(String)
        /// Already here, with the job's title.
        case held(String)
        case offer(JobFile, JobFileProvenance.Signature, signer: String?, revises: UpcomingJob?)
    }

    static func alreadyHeldMessage(_ title: String) -> String {
        "\(title) is already on this phone, at this revision."
    }
    static let olderRevisionMessage = "This phone already has a newer revision of this job, so this file wasn't added."
    static let conflictingRevisionMessage = "This job file says it is the same revision of a job this phone already has, but what it says is different. Ask the office to send it again as a new revision."
    static let unsignedRevisionMessage = "This job file isn't signed by your organisation, so it can't change a job that was. Ask the office to send it again, signed."
    static let startedJobMessage = "This job has already been started on this phone, so a job file doesn't change it. Ask the office to tell you what has changed."

    /// Validation, the signature check and the import policy, in that order.
    private func assess(_ data: Data) -> Assessment {
        guard seams.fieldAssistActive() else { return .refuse(Self.fieldAssistOffMessage) }
        let file: JobFile
        switch JobFileValidator.validate(data) {
        case .failure(let refusal):
            return .refuse(refusal.message)
        case .success(let valid):
            file = valid
        }
        let outcome = JobFileSignatureCheck.check(file, organisationKey: seams.organisationKey(),
                                                  organisationName: seams.organisationName())
        switch seams.policy().decide(outcome) {
        case .refuse(let message):
            return .refuse(message)
        case .offer(let signature, let signer):
            return standing(file, signature: signature, signer: signer)
        }
    }

    /// Where a file the policy would offer stands to what this phone already holds for the same
    /// office job (Contracts/job-file.md §5). A format-1 file has no identity and is always offered.
    private func standing(_ file: JobFile, signature: JobFileProvenance.Signature,
                          signer: String?) -> Assessment {
        guard let arriving = file.identity else { return .offer(file, signature, signer: signer, revises: nil) }
        func latest<T>(_ held: [(T, JobFileProvenance)]) -> (T, JobFile.Identity, JobFileProvenance)? {
            held.compactMap { item, provenance -> (T, JobFile.Identity, JobFileProvenance)? in
                guard let identity = provenance.identity, identity.jobID == arriving.jobID else { return nil }
                return (item, identity, provenance)
            }.max { $0.1.revision < $1.1.revision }
        }
        // A job ahead first: it can be revised.
        let ahead = (seams.store()?.jobs ?? []).compactMap { job in job.provenance.map { (job, $0) } }
        if let (job, held, provenance) = latest(ahead) {
            switch JobFile.relation(held: held, arriving: arriving) {
            case .same?: return .held(job.title)
            case .older?: return .refuse(Self.olderRevisionMessage)
            case .conflict?: return .refuse(Self.conflictingRevisionMessage)
            case .newer?:
                // An unsigned identifier is only a claim: it never revises a job that came signed.
                if provenance.signature == .signed, signature != .signed {
                    return .refuse(Self.unsignedRevisionMessage)
                }
                return .offer(file, signature, signer: signer, revises: job)
            case nil: break
            }
        }
        // A job already started is not changed by a job file, and is not offered a second time.
        if let (title, held, _) = latest(seams.startedJobFiles().map { ("This job", $0) }) {
            switch JobFile.relation(held: held, arriving: arriving) {
            case .same?: return .held(title)
            case .older?: return .refuse(Self.olderRevisionMessage)
            case .conflict?: return .refuse(Self.conflictingRevisionMessage)
            case .newer?: return .refuse(Self.startedJobMessage)
            case nil: break
            }
        }
        return .offer(file, signature, signer: signer, revises: nil)
    }

    /// The technician's answer. The only write in the whole path.
    @discardableResult
    func accept(_ decision: JobFileDecision) -> UpcomingJob? {
        guard case .review(let review) = stage, let store = seams.store() else { return nil }
        let written: UpcomingJob
        // A revision replaces the job it revises, whatever was tapped: it is never a second job.
        switch review.revises != nil ? JobFileDecision.update : decision {
        case .update:
            guard let existing = review.revises ?? review.duplicate else { return nil }
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
                    attachments: attachments, origin: origin, provenance: provenance, needs: needs,
                    brief: nil, createdAt: existing.createdAt)
    }
}
