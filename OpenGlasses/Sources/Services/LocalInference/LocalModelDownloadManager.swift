import CryptoKit
import Foundation

/// The one acquisition pipeline, used by curated catalog entries and custom repository imports
/// alike (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Download state machine").
///
/// What it guarantees, and why each guarantee is where it is:
///
///  - **One plan at a time, files sequentially.** Two multi-gigabyte downloads at once is a disk
///    and memory event on a phone, so a second plan is refused with a typed error rather than
///    queued behind a silent wait.
///  - **Nothing is trusted because the transport said so.** Status, final host, HTTPS, destination
///    containment, byte count and SHA-256 are all re-checked here, against a transport that a test
///    can make claim anything.
///  - **The marker is written last.** Files are validated in staging, the manifest is written
///    beside them, the whole directory is moved into place, and only then does `.complete` appear.
///    A power loss at any earlier step leaves the previous installation intact and a plan on disk
///    that says exactly where it stopped.
///  - **Progress is a persisted fact.** Every transition rewrites `download-plan.json`, so a
///    relaunch reads bytes rather than starting a progress bar from zero.
///
/// Everything except the live background session is injectable, so the exit criteria are exercised
/// against a temp directory and a fake transport with no network anywhere in the suite.
actor LocalModelDownloadManager {

    /// Failures that belong to the manager rather than to a plan.
    enum ManagerError: Error, Equatable {
        /// Another plan is still running. Acquisition is deliberately one-at-a-time.
        case anotherPlanActive(UUID)
        case planNotFound(UUID)
        /// The descriptor cannot be installed from — unpinned revision, missing digest, escaping path.
        case descriptorNotInstallable
        /// The fit report said no. The blockers travel with it so the caller can say which.
        case fitRefused([LocalModelFitReport.Blocker])
        /// The licence needs acceptance and none was supplied.
        case consentRequired
        case installationNotFound(LocalModelID)
        /// A path resolved outside the directory it must stay in. Never recovered from.
        case containmentRefused
        case storageUnavailable
    }

    /// Quarantine bounds. A failure record is a diagnostic, not an archive.
    static let quarantineRecordLimit = 10
    static let quarantineMaximumAge: TimeInterval = 7 * 24 * 3600

    private let repository: LocalModelRepository
    private let fileManager: FileManager
    private let transfer: any LocalModelFileTransferring
    private let now: @Sendable () -> Date
    /// Release a resident model before its files are removed. Injected as a closure so the manager
    /// never has to know about the coordinator (and so the suite never touches a `.shared` service).
    private let unloadIfResident: @Sendable (LocalModelID) async -> Void

    /// Bytes written for the file currently being fetched, keyed by plan. In memory only, and only
    /// for the progress bar: what survives a relaunch is the persisted plan, whose byte counts are
    /// recomputed from the files actually staged on disk. Cleared as soon as a file validates,
    /// because from that moment the persisted count is the better number.
    private var liveFileBytes: [UUID: (fileIndex: Int, bytes: Int64)] = [:]

    init(repository: LocalModelRepository,
         transfer: any LocalModelFileTransferring,
         fileManager: FileManager = .default,
         now: @escaping @Sendable () -> Date = Date.init,
         unloadIfResident: @escaping @Sendable (LocalModelID) async -> Void = { _ in }) {
        self.repository = repository
        self.transfer = transfer
        self.fileManager = fileManager
        self.now = now
        self.unloadIfResident = unloadIfResident
    }

    // MARK: - Locations

    func planDirectory(_ planID: UUID) -> URL {
        repository.stagingRoot.appendingPathComponent(planID.uuidString, isDirectory: true)
    }

    func filesDirectory(_ planID: UUID) -> URL {
        planDirectory(planID).appendingPathComponent(LocalModelDownloadPlan.filesDirectoryName,
                                                     isDirectory: true)
    }

    private func planFile(_ planID: UUID) -> URL {
        planDirectory(planID).appendingPathComponent(LocalModelDownloadPlan.fileName)
    }

    // MARK: - Reading plans

    /// Every plan on disk, oldest first. Unreadable plan files are skipped rather than guessed at.
    func plans() -> [LocalModelDownloadPlan] {
        guard let entries = try? fileManager.contentsOfDirectory(at: repository.stagingRoot,
                                                                 includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .compactMap { entry -> LocalModelDownloadPlan? in
                guard let planID = UUID(uuidString: entry.lastPathComponent) else { return nil }
                return readPlan(planID)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func plan(_ planID: UUID) -> LocalModelDownloadPlan? { readPlan(planID) }

    /// Progress for one plan: the bytes it has persisted, plus the live reading for the file in
    /// flight. Returns nil when there is no such plan.
    func progress(_ planID: UUID) -> (completedBytes: Int64, totalBytes: Int64)? {
        guard let plan = readPlan(planID) else { return nil }
        var completed = plan.completedBytes
        if let live = liveFileBytes[planID],
           plan.files.indices.contains(live.fileIndex),
           !plan.files[live.fileIndex].isValidated {
            // The persisted count already includes anything validated; the live figure belongs to
            // the one file that has not been.
            completed += min(live.bytes, plan.files[live.fileIndex].byteCount)
        }
        return (min(completed, plan.totalBytes), plan.totalBytes)
    }

    private func recordLiveBytes(planID: UUID, fileIndex: Int, bytes: Int64) {
        liveFileBytes[planID] = (fileIndex, bytes)
    }

    /// The plan currently occupying the pipeline, if any.
    func activePlan() -> LocalModelDownloadPlan? {
        plans().first { !$0.state.isTerminal }
    }

    private func readPlan(_ planID: UUID) -> LocalModelDownloadPlan? {
        guard let data = try? Data(contentsOf: planFile(planID)),
              var plan = try? Self.decoder.decode(LocalModelDownloadPlan.self, from: data) else {
            return nil
        }
        // A plan from a newer build is not resumed: its fields may mean something else, and a
        // half-understood resume is worse than starting the download again.
        guard plan.planVersion <= LocalModelDownloadPlan.currentPlanVersion else {
            plan.state = .failed(.terminal(.planUnreadable))
            return plan
        }
        return plan
    }

    @discardableResult
    private func persist(_ plan: LocalModelDownloadPlan) throws -> LocalModelDownloadPlan {
        let directory = planDirectory(plan.id)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            excludeFromBackup(directory)
            let data = try Self.encoder.encode(plan)
            try data.write(to: planFile(plan.id), options: .atomic)
        } catch {
            throw ManagerError.storageUnavailable
        }
        return plan
    }

    // MARK: - Creating a plan

    /// Create a plan for a descriptor whose fit has already been judged.
    ///
    /// The fit report is required rather than recomputed: free space and process headroom are
    /// readings taken on the main actor next to the surface that showed them, and a plan created
    /// from a *different* reading than the one the user consented to is not the plan they agreed
    /// to.
    func createPlan(descriptor: LocalModelDescriptor,
                    origin: LocalModelDownloadPlan.Origin,
                    fit: LocalModelFitReport) throws -> LocalModelDownloadPlan {
        if let active = activePlan() { throw ManagerError.anotherPlanActive(active.id) }
        guard fit.canInstall else { throw ManagerError.fitRefused(fit.blockers) }
        guard var plan = LocalModelDownloadPlan(descriptor: descriptor, origin: origin, now: now()) else {
            throw ManagerError.descriptorNotInstallable
        }
        try plan.advance(to: .awaitingConsent, now: now())
        let stored = try persist(plan)
        log(.downloadPlanned, plan: stored)
        return stored
    }

    /// Record consent and queue the plan. A licence that requires acceptance and did not get it
    /// leaves the plan exactly where it was.
    func grantConsent(planID: UUID,
                      acceptedLicenseRevision: String? = nil) throws -> LocalModelDownloadPlan {
        guard var plan = readPlan(planID) else { throw ManagerError.planNotFound(planID) }
        if plan.descriptor.license.requiresAcceptance {
            guard let accepted = acceptedLicenseRevision,
                  plan.descriptor.license.revision == nil || accepted == plan.descriptor.license.revision
            else { throw ManagerError.consentRequired }
        }
        plan.acceptedLicenseRevision = acceptedLicenseRevision
        try plan.advance(to: .queued, now: now())
        return try persist(plan)
    }

    // MARK: - Running

    /// Run a queued (or resumable) plan to completion. Returns the plan in its final state; a
    /// failure is a state, not a thrown error, because a failed plan is still a thing the user can
    /// see and retry.
    @discardableResult
    func run(planID: UUID) async -> LocalModelDownloadPlan? {
        guard var plan = readPlan(planID) else { return nil }
        if case .failed(let failure) = plan.state, failure.isRetryable {
            guard (try? plan.advance(to: .queued, now: now())) != nil else { return plan }
            plan = (try? persist(plan)) ?? plan
        }
        guard !plan.state.isTerminal else { return plan }
        // Consent is a state, not a parameter: a plan that never reached `queued` has not been
        // agreed to, and running it would be starting a download nobody approved.
        switch plan.state {
        case .queued, .downloading, .validating, .installing: break
        default: return fail(plan, reason: .consentMissing)
        }

        log(.downloadStarted, plan: plan)
        while let index = plan.nextFileIndex {
            do {
                plan = try await fetchAndValidate(plan, fileIndex: index)
            } catch let reason as LocalModelDownloadPlan.FailureReason {
                return fail(plan, reason: reason)
            } catch is CancellationError {
                return cancelPlan(plan)
            } catch ManagerError.storageUnavailable {
                return fail(plan, reason: .storageUnavailable)
            } catch is LocalModelDownloadPlan.TransitionError {
                // The plan asked for a move its own table forbids, which means the record on disk
                // no longer describes a run that can continue.
                return fail(plan, reason: .planUnreadable)
            } catch {
                return fail(plan, reason: .transport)
            }
            if case .cancelled = plan.state { return plan }
        }
        return finishInstall(plan)
    }

    /// One file: fetch, then re-check everything the outcome claims, then stage it.
    private func fetchAndValidate(_ plan: LocalModelDownloadPlan,
                                  fileIndex: Int) async throws -> LocalModelDownloadPlan {
        var plan = plan
        guard plan.files.indices.contains(fileIndex) else {
            throw LocalModelDownloadPlan.FailureReason.planUnreadable
        }
        let file = plan.files[fileIndex]

        // Containment first, and before the fetch: a path that will not stay inside the plan's own
        // files directory must never reach the network at all, whatever else is wrong with it.
        guard let destination = LocalModelPath.resolve(file.relativePath,
                                                       under: filesDirectory(plan.id)) else {
            throw LocalModelDownloadPlan.FailureReason.containmentRefused
        }
        // Then the URL, from validated pieces. A reference that will not parse, or a revision that
        // is not an exact commit, cannot produce one — and that is a refusal, not a retry.
        guard case .success(let reference) =
                LocalModelRepositoryReference.parse(plan.descriptor.repositoryID),
              let url = reference.fileURL(revision: plan.descriptor.revision,
                                          relativePath: file.relativePath) else {
            throw LocalModelDownloadPlan.FailureReason.revisionMismatch
        }

        try plan.advance(to: .downloading(fileIndex: fileIndex), now: now())
        plan = try persist(plan)

        let outcome: LocalModelFileTransferOutcome
        do {
            let planID = plan.id
            outcome = try await transfer.transfer(.init(
                identifier: LocalModelTransferIdentifier(planID: planID, fileIndex: fileIndex),
                url: url,
                expectedBytes: file.byteCount,
                onProgress: { [weak self] written in
                    // Already throttled by the transport; one hop per megabyte is affordable and
                    // is what keeps the actor's state the single owner of the reading.
                    Task { await self?.recordLiveBytes(planID: planID,
                                                       fileIndex: fileIndex,
                                                       bytes: written) }
                }))
        } catch LocalModelFileTransferError.cancelled {
            throw CancellationError()
        } catch LocalModelFileTransferError.redirectRefused {
            throw LocalModelDownloadPlan.FailureReason.redirectHostRejected
        } catch {
            throw LocalModelDownloadPlan.FailureReason.transport
        }
        defer { try? fileManager.removeItem(at: outcome.fileURL) }

        // A cancellation can land while a fetch is in flight — the actor lets `cancel` interleave
        // at exactly these suspension points. Continuing here would resurrect a plan the user
        // stopped, and would rewrite the directory cancellation just removed.
        guard let current = readPlan(plan.id), !isCancelled(current) else { throw CancellationError() }

        try plan.advance(to: .validating(fileIndex: fileIndex), now: now())
        plan = try persist(plan)

        guard (200..<300).contains(outcome.statusCode) else {
            throw LocalModelDownloadPlan.FailureReason.httpStatus
        }
        // Re-validated per response, not per request: this is the check a redirect is trying to
        // get past.
        let finalURL = outcome.finalURL
        guard (finalURL?.scheme ?? "").lowercased() == "https" else {
            throw LocalModelDownloadPlan.FailureReason.insecureRedirect
        }
        guard LocalModelRepositoryReference.isAllowedDownloadURL(finalURL) else {
            throw LocalModelDownloadPlan.FailureReason.redirectHostRejected
        }
        let stagedBytes = fileSize(outcome.fileURL)
        guard stagedBytes == file.byteCount, outcome.byteCount == file.byteCount else {
            throw LocalModelDownloadPlan.FailureReason.sizeMismatch
        }
        guard let digest = try? LocalModelDigest.sha256(ofFileAt: outcome.fileURL),
              digest == file.sha256.lowercased() else {
            throw LocalModelDownloadPlan.FailureReason.digestMismatch
        }

        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: outcome.fileURL, to: destination)
        } catch {
            throw LocalModelDownloadPlan.FailureReason.storageUnavailable
        }

        plan.markValidated(fileIndex: fileIndex, byteCount: file.byteCount, now: now())
        liveFileBytes[plan.id] = nil
        if let next = plan.nextFileIndex {
            try plan.advance(to: .downloading(fileIndex: next), now: now())
        }
        return try persist(plan)
    }

    /// Manifest → move → marker. The order is the crash-consistency argument, and it lives in the
    /// repository so "installed" has exactly one definition.
    private func finishInstall(_ plan: LocalModelDownloadPlan) -> LocalModelDownloadPlan {
        var plan = plan
        guard plan.files.allSatisfy(\.isValidated) else { return fail(plan, reason: .installFailed) }

        if case .installing = plan.state {} else {
            guard (try? plan.advance(to: .installing, now: now())) != nil else {
                return fail(plan, reason: .installFailed)
            }
            plan = (try? persist(plan)) ?? plan
        }

        let installation = InstalledLocalModel(
            descriptor: plan.descriptor,
            storage: .managed(directoryName: plan.descriptor.id.storageComponent),
            installedAt: now(),
            validatedFiles: plan.files.map(\.modelFile),
            acceptedLicenseRevision: plan.acceptedLicenseRevision)

        do {
            try repository.install(installation, movingContentsOf: filesDirectory(plan.id))
        } catch {
            return fail(plan, reason: .installFailed)
        }

        guard (try? plan.advance(to: .installed, now: now())) != nil else {
            return fail(plan, reason: .installFailed)
        }
        plan = (try? persist(plan)) ?? plan
        log(.installCompleted, plan: plan)
        liveFileBytes[plan.id] = nil
        // The plan has done its job; its directory goes now that nothing depends on it.
        removePlanDirectory(plan.id)
        return plan
    }

    private func fail(_ plan: LocalModelDownloadPlan,
                      reason: LocalModelDownloadPlan.FailureReason) -> LocalModelDownloadPlan {
        // The persisted plan is further along than the caller's copy — it was rewritten at each
        // transition — so the failure is recorded against the step that actually failed.
        var plan = readPlan(plan.id) ?? plan
        let failure = LocalModelDownloadPlan.Failure.classify(reason)
        try? plan.advance(to: .failed(failure), now: now())
        let stored = (try? persist(plan)) ?? plan
        log(.downloadFailed, plan: stored, detail: reason.rawValue)
        if !failure.isRetryable {
            quarantine(stored, reason: reason)
            removeStagedFiles(stored.id)
        }
        return stored
    }

    // MARK: - Cancellation

    /// Cancel one plan: its tasks, then its state, then its staged bytes. Only this plan's
    /// directory is touched, and only after the path is proved to be beneath the staging root.
    @discardableResult
    func cancel(planID: UUID) async -> LocalModelDownloadPlan? {
        await transfer.cancelTasks(forPlan: planID)
        guard let plan = readPlan(planID) else { return nil }
        return cancelPlan(plan)
    }

    private func cancelPlan(_ plan: LocalModelDownloadPlan) -> LocalModelDownloadPlan {
        var plan = readPlan(plan.id) ?? plan
        try? plan.advance(to: .cancelled, now: now())
        // Already cleared by an earlier cancellation: reporting it again is fine, rewriting its
        // directory is not.
        guard readPlan(plan.id) != nil else { return plan }
        let stored = (try? persist(plan)) ?? plan
        liveFileBytes[stored.id] = nil
        log(.downloadCancelled, plan: stored)
        removePlanDirectory(stored.id)
        return stored
    }

    // MARK: - Recovery

    /// Rebuild state after a relaunch: re-derive per-file progress from what is actually on disk,
    /// discard finished plans, and report what each remaining plan wants to do next.
    ///
    /// Nothing here resumes anything on its own. A multi-gigabyte download is not something to
    /// restart because an app launched — invariant 12 is explicit that acquisition is user-driven.
    @discardableResult
    func restore() async -> [(plan: LocalModelDownloadPlan, recovery: LocalModelDownloadPlan.Recovery)] {
        let live = Set(await transfer.liveIdentifiers().map(\.planID))
        var result: [(LocalModelDownloadPlan, LocalModelDownloadPlan.Recovery)] = []

        for var plan in plans() {
            // The one interruption that leaves no staged files and no marker: the directory was
            // already moved into place and the process died before `.complete`. Recomputing
            // progress here would find nothing on disk and conclude the download must start again,
            // over a perfectly good installation.
            if case .installing = plan.state,
               !fileManager.fileExists(atPath: filesDirectory(plan.id).path),
               fileManager.fileExists(atPath: repository.directory(for: plan.descriptor.id)
                   .appendingPathComponent(LocalModelRepository.manifestFileName).path) {
                let finished = finishInstall(plan)
                result.append((finished, finished.recovery))
                continue
            }

            // Progress from bytes on disk, not from a callback that no longer exists. A file whose
            // staged size no longer matches is un-validated: the digest was computed over bytes
            // that are gone.
            for index in plan.files.indices {
                guard let staged = LocalModelPath.resolve(plan.files[index].relativePath,
                                                          under: filesDirectory(plan.id)) else {
                    plan.files[index].completedBytes = 0
                    plan.files[index].isValidated = false
                    continue
                }
                let size = fileSize(staged)
                plan.files[index].completedBytes = min(size, plan.files[index].byteCount)
                if size != plan.files[index].byteCount { plan.files[index].isValidated = false }
            }

            let recovery = plan.recovery
            switch recovery {
            case .discard:
                removePlanDirectory(plan.id)
                continue
            case .finishInstall where plan.files.allSatisfy(\.isValidated):
                plan = finishInstall(plan)
                result.append((plan, plan.recovery))
                continue
            default:
                break
            }
            _ = try? persist(plan)
            log(.downloadRecovered, plan: plan,
                detail: live.contains(plan.id) ? "taskLive" : "taskAbsent")
            result.append((plan, recovery))
        }
        return result
    }

    // MARK: - Deletion

    /// Delete an installed model: stop anything fetching it, release it if it is resident, then
    /// remove exactly its directory after proving that directory is beneath the model root.
    func deleteInstallation(_ id: LocalModelID) async throws {
        for plan in plans() where plan.descriptor.id == id && !plan.state.isTerminal {
            _ = await cancel(planID: plan.id)
        }
        guard let installation = repository.installation(for: id) else {
            throw ManagerError.installationNotFound(id)
        }
        await unloadIfResident(id)
        do {
            try repository.remove(installation)
        } catch LocalModelRepository.RecordError.notWritable {
            throw ManagerError.containmentRefused
        }
        log(.deleted, id: id, origin: .curatedCatalog)
    }

    // MARK: - Quarantine

    /// Record why a plan failed terminally. Counts, sizes and a case name — never a path, a URL or
    /// a repository name, because an imported repository id is text a user typed.
    private func quarantine(_ plan: LocalModelDownloadPlan,
                            reason: LocalModelDownloadPlan.FailureReason) {
        struct Record: Codable {
            let planID: String
            let origin: String
            let reason: String
            let failedFileIndex: Int?
            let expectedBytes: Int64
            let stagedBytes: Int64
            let recordedAt: Date
        }
        let index = plan.state.fileIndex.flatMap { plan.files.indices.contains($0) ? $0 : nil }
        let record = Record(planID: plan.id.uuidString,
                            origin: plan.origin.rawValue,
                            reason: reason.rawValue,
                            failedFileIndex: index,
                            expectedBytes: index.map { plan.files[$0].byteCount } ?? 0,
                            stagedBytes: plan.completedBytes,
                            recordedAt: now())
        let directory = repository.quarantineRoot.appendingPathComponent(plan.id.uuidString,
                                                                         isDirectory: true)
        guard (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let data = try? Self.encoder.encode(record) else { return }
        try? data.write(to: directory.appendingPathComponent("validation-failure.json"), options: .atomic)
        excludeFromBackup(directory)
        pruneQuarantine()
    }

    /// Bounded by count and age, so a repeatedly failing import cannot grow a diagnostic archive.
    private func pruneQuarantine() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: repository.quarantineRoot,
            includingPropertiesForKeys: [.creationDateKey]) else { return }
        let dated = entries.map { url -> (URL, Date) in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date(timeIntervalSince1970: 0)
            return (url, created)
        }.sorted { $0.1 > $1.1 }

        let cutoff = now().addingTimeInterval(-Self.quarantineMaximumAge)
        for (offset, entry) in dated.enumerated() {
            if offset >= Self.quarantineRecordLimit || entry.1 < cutoff {
                try? fileManager.removeItem(at: entry.0)
            }
        }
    }

    // MARK: - Filesystem helpers

    /// Remove a plan's whole directory, after proving it is beneath the staging root. The
    /// containment check is not ceremony: this is the one place the pipeline deletes a directory
    /// derived from a value that has been round-tripped through disk.
    private func removePlanDirectory(_ planID: UUID) {
        let directory = planDirectory(planID)
        guard Self.isContained(directory, within: repository.stagingRoot) else { return }
        try? fileManager.removeItem(at: directory)
    }

    private func removeStagedFiles(_ planID: UUID) {
        let directory = filesDirectory(planID)
        guard Self.isContained(directory, within: repository.stagingRoot) else { return }
        try? fileManager.removeItem(at: directory)
    }

    private func isCancelled(_ plan: LocalModelDownloadPlan) -> Bool {
        if case .cancelled = plan.state { return true }
        return false
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    static func isContained(_ url: URL, within root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    // MARK: - Diagnostics

    /// Log a plan event.
    ///
    /// A curated model id is a public catalog token and is logged; an *imported* repository id is
    /// text the user typed and is not. Both cases carry the origin, so a log reader can still tell
    /// which pipeline a line came from without the line naming anything private.
    private func log(_ event: PrivacyLog.LocalModelEvent,
                     plan: LocalModelDownloadPlan,
                     detail: String? = nil) {
        log(event, id: plan.descriptor.id, origin: plan.origin, detail: detail,
            percent: Int(plan.fractionCompleted * 100))
    }

    private func log(_ event: PrivacyLog.LocalModelEvent,
                     id: LocalModelID,
                     origin: LocalModelDownloadPlan.Origin,
                     detail: String? = nil,
                     percent: Int? = nil) {
        let isPublicToken = origin == .curatedCatalog
            && LocalModelCatalog.catalogedModelIDs.contains(id.rawValue)
        PrivacyLog.localModel(event,
                              model: isPublicToken ? PrivacyToken(id.rawValue) : nil,
                              detail: PrivacyToken(detail ?? origin.rawValue),
                              percent: percent)
    }

    // MARK: - Coding

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Streaming SHA-256 over a file.
///
/// Chunked rather than `Data(contentsOf:)` for the reason the plan states plainly: model files are
/// gigabytes, and buffering one to hash it would undo the whole point of streaming it to disk.
enum LocalModelDigest {
    /// Bytes read per update. Large enough to keep the hash fed, small enough to be invisible in a
    /// memory graph.
    static let chunkBytes = 1 << 20

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
