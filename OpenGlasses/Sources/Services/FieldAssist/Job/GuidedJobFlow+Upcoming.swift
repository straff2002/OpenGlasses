import Foundation

/// Jobs ahead, the brief before site, and starting one on arrival (Plan FO §7, P3c).
///
/// The same rules as the rest of the flow: a job ahead is created only by the technician (said,
/// typed, or a job file they accepted on its review sheet); the brief is assembled by the app from
/// sources it can cite and spoken by the app; and starting a job ahead is the ordinary `startJob`
/// — the intake still confirms the number, and nothing about the job ahead changes equipment or
/// creates a task.
extension GuidedJobFlow {

    // MARK: - The list

    /// Add a job ahead. Returns it, or nil when the flow has no store to put it in.
    @discardableResult
    func addUpcomingJob(_ job: UpcomingJob) -> UpcomingJob? {
        guard let upcoming else { return nil }
        upcoming.add(job)
        return upcoming.job(id: job.id)
    }

    /// The job ahead "next job" means, when there is one.
    var nextUpcomingJob: UpcomingJob? { upcoming?.next }

    // MARK: - The brief

    /// Assemble the brief for a job ahead from what this phone can cite: the job itself, this
    /// phone's history, and the vault a new job would be started on. Saved onto the job, so the
    /// Job tab shows the one that was heard and the visit starts from it.
    @discardableResult
    func assembleBrief(jobId: String, vaultId: String = Config.fieldAssistDefaultVaultId,
                       now: Date = Date()) -> JobBrief? {
        guard let job = upcoming?.job(id: jobId) else { return nil }
        let brief = JobBriefAssembler.assemble(briefInputs(for: job, vaultId: vaultId, now: now))
        upcoming?.saveBrief(brief, jobId: jobId)
        return brief
    }

    /// Assemble the brief and read it out. Returns false when the job is not on this phone.
    @discardableResult
    func briefAloud(jobId: String) async -> Bool {
        guard let job = upcoming?.job(id: jobId), let brief = assembleBrief(jobId: jobId) else {
            return false
        }
        await seams.speak(JobBriefSpeech.spoken(brief, title: job.title))
        return true
    }

    /// "Say more about the fault." Reads one section of the job's last brief in full.
    ///
    /// - Returns: what was read, or nil when the request named no section or there is no brief.
    @discardableResult
    func moreOfBrief(jobId: String, request: String) async -> String? {
        guard let brief = upcoming?.job(id: jobId)?.brief,
              let kind = JobBriefSpeech.section(named: request) else { return nil }
        let line = JobBriefSpeech.more(kind, in: brief)
        await seams.speak(line)
        return line
    }

    private func briefInputs(for job: UpcomingJob, vaultId: String, now: Date) -> JobBriefAssembler.Inputs {
        let history = JobHistoryIndex(sessions: sessions.history)
        guard let manifest = VaultRegistry.shared.manifest(id: vaultId),
              VaultRegistry.shared.isUnlocked(manifest) else {
            // A locked or missing vault contributes nothing, and every vault section says so.
            return JobBriefAssembler.Inputs(job: job, history: history, vaultName: vaultId, now: now)
        }
        let store = VaultRegistry.shared.store(for: manifest)
        let files = store.readAll()
        let documentStore = sessions.documentStore
        let retriever: VaultRetriever? = (manifest.hasDocuments && documentStore != nil)
            ? sessions.manualRetriever(store: store) : nil
        return JobBriefAssembler.Inputs(
            job: job, history: history, vaultName: manifest.name, coreFiles: files,
            procedures: ProcedureLibrary(store: store).all,
            manualPassages: { text in
                retriever?.retrieve(.init(turn: text, limit: JobBriefAssembler.passageLimit)).passages ?? []
            },
            now: now)
    }

    // MARK: - Starting one on site

    /// Start the job ahead: the ordinary `startJob`, carrying its number, then its site, fault
    /// report, brief and provenance onto the new session. The job ahead leaves the list — it is the
    /// job now.
    @discardableResult
    func startUpcomingJob(id: String, vaultId: String = Config.fieldAssistDefaultVaultId,
                          mode: FieldSession.Mode = .aiOnly) throws -> FieldSession {
        guard let job = upcoming?.job(id: id) else { throw UpcomingJobError.notFound }
        let session = try startJob(vaultId: vaultId, assetId: nil, mode: mode,
                                   jobReference: job.jobReference)
        sessions.applyJobAhead(job)
        upcoming?.remove(id: id)
        return sessions.activeSession ?? session
    }

    /// What the app says as a job ahead starts. The number is said back, so the technician hears
    /// which job the time is now counting against; a job ahead with no number is asked for one by
    /// the intake exactly as any other job is.
    static func startedLine(for job: UpcomingJob) -> String {
        guard let reference = job.jobReference else {
            return "Started \(job.title)."
        }
        let site = job.site.headline.map { " at \($0)" } ?? ""
        return "Starting job \(reference)\(site)."
    }
}

enum UpcomingJobError: LocalizedError, Equatable {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "That upcoming job is no longer on this phone."
        }
    }
}
