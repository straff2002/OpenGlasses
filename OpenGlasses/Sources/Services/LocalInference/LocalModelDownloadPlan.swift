import Foundation

/// The persisted record of one model acquisition, and the state machine it may move through
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Download state machine").
///
/// ```text
/// planned → awaitingConsent → queued → downloading → validating → installing → installed
///                           ↘ cancelled
/// downloading/validating/installing → failed(retryable | terminal)
/// ```
///
/// The plan is the durable half of the pipeline: it lives at
/// `staging/<plan id>/download-plan.json`, is rewritten after every transition, and carries the
/// per-file byte counts that make progress survive a relaunch. Nothing here touches the network or
/// the filesystem — the transition table, the identifiers and the recovery decision are all pure,
/// which is what lets "the app recovers cleanly from termination during each transition" be a test
/// rather than a hope.
struct LocalModelDownloadPlan: Codable, Equatable, Sendable, Identifiable {

    /// Bumped when the plan's *meaning* changes. A plan written by a newer build and found by an
    /// older one is discarded rather than half-understood: a resumed download is not worth the
    /// risk of misreading which files were already validated.
    static let currentPlanVersion = 1
    static let fileName = "download-plan.json"
    /// Subdirectory of the plan directory holding the partial and completed files. Separate from
    /// the plan file itself so the install step can move the *files* into place and leave the plan
    /// behind to record that it did.
    static let filesDirectoryName = "files"

    /// Where the plan came from. Curated ids are public catalog tokens; an imported repository id
    /// is text the user typed, and the two are logged differently for exactly that reason.
    enum Origin: String, Codable, Sendable {
        case curatedCatalog
        case repositoryImport
    }

    /// One file to fetch, with everything needed to prove it arrived intact.
    struct PlannedFile: Codable, Equatable, Sendable {
        let relativePath: String
        let byteCount: Int64
        /// Lowercase hex SHA-256, always present: a plan cannot be built around a file without one.
        let sha256: String
        let role: LocalModelFile.Role
        /// Bytes on disk for this file, as last persisted. This — not an in-memory callback — is
        /// what progress is computed from after a relaunch.
        var completedBytes: Int64
        /// Size and digest both verified against the staged bytes.
        var isValidated: Bool

        init(relativePath: String,
             byteCount: Int64,
             sha256: String,
             role: LocalModelFile.Role,
             completedBytes: Int64 = 0,
             isValidated: Bool = false) {
            self.relativePath = relativePath
            self.byteCount = byteCount
            self.sha256 = sha256
            self.role = role
            self.completedBytes = completedBytes
            self.isValidated = isValidated
        }

        var modelFile: LocalModelFile {
            LocalModelFile(relativePath: relativePath, byteCount: byteCount, sha256: sha256, role: role)
        }
    }

    /// Why a plan failed, in a closed vocabulary. Every case is a case name and nothing else, so a
    /// failure can be logged without any of the text that produced it.
    enum FailureReason: String, Codable, Equatable, Sendable, Error {
        case transport
        case httpStatus
        case sizeMismatch
        case digestMismatch
        case redirectHostRejected
        case insecureRedirect
        case containmentRefused
        case revisionMismatch
        case storageUnavailable
        case installFailed
        case planUnreadable
        case consentMissing
        case fitRefused
    }

    /// Retryable means "the same plan may run again"; terminal means the plan is finished and a
    /// new one must be created. Digest and containment failures are terminal on purpose — fetching
    /// the same bytes again is not a fix, and retrying a refusal is how a refusal becomes a loop.
    enum Failure: Equatable, Sendable {
        case retryable(FailureReason)
        case terminal(FailureReason)

        var reason: FailureReason {
            switch self {
            case .retryable(let reason), .terminal(let reason): return reason
            }
        }

        var isRetryable: Bool {
            if case .retryable = self { return true }
            return false
        }

        /// The classification, in one place. Anything that could plausibly succeed on the next
        /// attempt is retryable; anything that says the remote bytes or the plan itself are wrong
        /// is not.
        static func classify(_ reason: FailureReason) -> Failure {
            switch reason {
            case .transport, .httpStatus, .storageUnavailable, .installFailed:
                return .retryable(reason)
            case .sizeMismatch, .digestMismatch, .redirectHostRejected, .insecureRedirect,
                 .containmentRefused, .revisionMismatch, .planUnreadable, .consentMissing,
                 .fitRefused:
                return .terminal(reason)
            }
        }
    }

    enum State: Equatable, Sendable {
        case planned
        case awaitingConsent
        case queued
        case downloading(fileIndex: Int)
        case validating(fileIndex: Int)
        case installing
        case installed
        case cancelled
        case failed(Failure)

        /// No further work happens on a plan in a terminal state.
        var isTerminal: Bool {
            switch self {
            case .installed, .cancelled: return true
            case .failed(let failure): return !failure.isRetryable
            default: return false
            }
        }

        /// The file this state is working on, when it is working on one.
        var fileIndex: Int? {
            switch self {
            case .downloading(let index), .validating(let index): return index
            default: return nil
            }
        }
    }

    var planVersion: Int
    let id: UUID
    let descriptor: LocalModelDescriptor
    let origin: Origin
    var files: [PlannedFile]
    var state: State
    let createdAt: Date
    var updatedAt: Date
    /// Licence revision the user accepted, recorded before the download is allowed to start.
    var acceptedLicenseRevision: String?

    // MARK: - Construction

    /// Build a plan from a descriptor. Returns nil when the descriptor is not installable — an
    /// unpinned revision, a missing digest, a path that escapes the model root. That refusal is the
    /// same `installationFaults()` gate the catalog uses, applied one more time at the point where
    /// files would actually be fetched.
    init?(descriptor: LocalModelDescriptor,
          origin: Origin,
          id: UUID = UUID(),
          now: Date = Date()) {
        guard descriptor.installationFaults().isEmpty else { return nil }
        guard !descriptor.files.isEmpty else { return nil }
        self.planVersion = Self.currentPlanVersion
        self.id = id
        self.descriptor = descriptor
        self.origin = origin
        self.files = descriptor.files.map {
            PlannedFile(relativePath: $0.relativePath,
                        byteCount: $0.byteCount,
                        sha256: $0.sha256.lowercased(),
                        role: $0.role)
        }
        self.state = .planned
        self.createdAt = now
        self.updatedAt = now
        self.acceptedLicenseRevision = nil
    }

    // MARK: - Progress

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    /// Progress from persisted bytes. Deliberately not from a callback: after a relaunch there is
    /// no callback, and a progress bar that resets to zero reads as lost work.
    var completedBytes: Int64 { files.reduce(0) { $0 + min($1.completedBytes, $1.byteCount) } }

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// Index of the first file still to fetch, or nil when every file has validated.
    var nextFileIndex: Int? { files.firstIndex { !$0.isValidated } }

    // MARK: - Transitions

    /// Whether `next` may follow the current state. The single table; both the manager and the
    /// recovery path consult it rather than each having an opinion.
    func canTransition(to next: State) -> Bool {
        switch (state, next) {
        case (_, .cancelled):
            return !state.isTerminal || isCancellableTerminal
        case (_, .failed):
            // A terminal state does not fail again; anything still in flight may.
            return !state.isTerminal
        case (.planned, .awaitingConsent), (.planned, .queued):
            return true
        case (.awaitingConsent, .queued):
            return true
        case (.queued, .downloading(let index)):
            return index == (nextFileIndex ?? 0)
        case (.downloading(let current), .validating(let index)):
            return current == index
        case (.validating(let current), .downloading(let index)):
            return index > current && files.indices.contains(index)
        case (.validating, .installing):
            return files.allSatisfy(\.isValidated)
        case (.installing, .installed):
            return files.allSatisfy(\.isValidated)
        case (.failed(let failure), .queued):
            return failure.isRetryable
        // A resumed plan re-enters the file it was working on rather than starting over.
        case (.downloading(let current), .downloading(let index)),
             (.validating(let current), .validating(let index)):
            return current == index
        default:
            return false
        }
    }

    /// Cancelling an already-cancelled plan is a no-op rather than an error; cancelling an
    /// installed one is not, because the files are in use and deletion is a different operation
    /// with different consequences.
    private var isCancellableTerminal: Bool {
        switch state {
        case .cancelled: return true
        case .failed(let failure): return !failure.isRetryable
        default: return false
        }
    }

    enum TransitionError: Error, Equatable {
        case notAllowed
    }

    mutating func advance(to next: State, now: Date = Date()) throws {
        guard canTransition(to: next) else { throw TransitionError.notAllowed }
        state = next
        updatedAt = now
    }

    /// Record a validated file. Separate from the transition so "validated" is a fact about the
    /// file, not a side effect of moving state.
    mutating func markValidated(fileIndex: Int, byteCount: Int64, now: Date = Date()) {
        guard files.indices.contains(fileIndex) else { return }
        files[fileIndex].completedBytes = byteCount
        files[fileIndex].isValidated = true
        updatedAt = now
    }

    mutating func recordProgress(fileIndex: Int, completedBytes: Int64, now: Date = Date()) {
        guard files.indices.contains(fileIndex) else { return }
        files[fileIndex].completedBytes = max(0, min(completedBytes, files[fileIndex].byteCount))
        updatedAt = now
    }

    // MARK: - Recovery

    /// What a plan found on disk after a relaunch should do next.
    enum Recovery: Equatable, Sendable {
        /// Waiting for the user; nothing to resume.
        case awaitUser
        /// Resume fetching, starting at this file. Any partially fetched file is refetched — a
        /// resumed byte range cannot be verified against the digest without the bytes already on
        /// disk being trustworthy, and they are exactly what a crash makes untrustworthy.
        case resumeDownload(fileIndex: Int)
        /// Every file validated but the install did not finish. Finish it.
        case finishInstall
        /// Nothing left to do; the plan directory can be removed.
        case discard
        /// A retryable failure the user may retry.
        case offerRetry(FailureReason)
    }

    var recovery: Recovery {
        switch state {
        case .planned, .awaitingConsent:
            return .awaitUser
        case .queued:
            return nextFileIndex.map { .resumeDownload(fileIndex: $0) } ?? .finishInstall
        case .downloading(let index), .validating(let index):
            let resume = nextFileIndex ?? index
            return files.allSatisfy(\.isValidated) ? .finishInstall : .resumeDownload(fileIndex: resume)
        case .installing:
            // Only an install whose files all still validate can be finished; anything else goes
            // back to fetching, because "installing" is not evidence that the bytes are there.
            return files.allSatisfy(\.isValidated)
                ? .finishInstall
                : .resumeDownload(fileIndex: nextFileIndex ?? 0)
        case .installed, .cancelled:
            return .discard
        case .failed(let failure):
            return failure.isRetryable ? .offerRetry(failure.reason) : .discard
        }
    }

    // MARK: - Codable
    //
    // Hand-written so the state is stored as a readable tagged object
    // (`{"name":"downloading","fileIndex":1}`) rather than Swift's synthesized enum shape. A plan
    // file is something a person may have to read while diagnosing a stuck download.

    private enum CodingKeys: String, CodingKey {
        case planVersion, id, descriptor, origin, files, state, createdAt, updatedAt
        case acceptedLicenseRevision
    }

    private struct StoredState: Codable, Equatable {
        var name: String
        var fileIndex: Int?
        var failureReason: FailureReason?
        var isRetryable: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planVersion = (try? container.decode(Int.self, forKey: .planVersion)) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        descriptor = try container.decode(LocalModelDescriptor.self, forKey: .descriptor)
        origin = (try? container.decode(Origin.self, forKey: .origin)) ?? .curatedCatalog
        files = try container.decode([PlannedFile].self, forKey: .files)
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        acceptedLicenseRevision = try? container.decode(String.self, forKey: .acceptedLicenseRevision)

        let stored = try container.decode(StoredState.self, forKey: .state)
        state = Self.state(from: stored)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(planVersion, forKey: .planVersion)
        try container.encode(id, forKey: .id)
        try container.encode(descriptor, forKey: .descriptor)
        try container.encode(origin, forKey: .origin)
        try container.encode(files, forKey: .files)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(acceptedLicenseRevision, forKey: .acceptedLicenseRevision)
        try container.encode(Self.stored(from: state), forKey: .state)
    }

    private static func stored(from state: State) -> StoredState {
        switch state {
        case .planned: return StoredState(name: "planned")
        case .awaitingConsent: return StoredState(name: "awaitingConsent")
        case .queued: return StoredState(name: "queued")
        case .downloading(let index): return StoredState(name: "downloading", fileIndex: index)
        case .validating(let index): return StoredState(name: "validating", fileIndex: index)
        case .installing: return StoredState(name: "installing")
        case .installed: return StoredState(name: "installed")
        case .cancelled: return StoredState(name: "cancelled")
        case .failed(let failure):
            return StoredState(name: "failed",
                               failureReason: failure.reason,
                               isRetryable: failure.isRetryable)
        }
    }

    /// An unreadable or unknown stored state becomes a terminal `planUnreadable` failure rather
    /// than a guess. A plan whose state cannot be established must not be resumed.
    private static func state(from stored: StoredState) -> State {
        switch stored.name {
        case "planned": return .planned
        case "awaitingConsent": return .awaitingConsent
        case "queued": return .queued
        case "downloading": return stored.fileIndex.map { .downloading(fileIndex: $0) } ?? .queued
        case "validating": return stored.fileIndex.map { .validating(fileIndex: $0) } ?? .queued
        case "installing": return .installing
        case "installed": return .installed
        case "cancelled": return .cancelled
        case "failed":
            let reason = stored.failureReason ?? .planUnreadable
            return .failed(stored.isRetryable == true ? .retryable(reason) : .terminal(reason))
        default:
            return .failed(.terminal(.planUnreadable))
        }
    }
}

/// The stable identifier that ties a background transfer task to a plan and a file.
///
/// It is written into the task's `taskDescription`, which the system preserves across app
/// termination — so after a relaunch the mapping is rebuilt by *reading the tasks*, not by
/// remembering anything.
struct LocalModelTransferIdentifier: Equatable, Hashable, Sendable, CustomStringConvertible {
    let planID: UUID
    let fileIndex: Int

    var description: String { "\(planID.uuidString)#\(fileIndex)" }

    init(planID: UUID, fileIndex: Int) {
        self.planID = planID
        self.fileIndex = fileIndex
    }

    init?(_ raw: String?) {
        guard let raw else { return nil }
        let parts = raw.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let planID = UUID(uuidString: String(parts[0])),
              let index = Int(parts[1]), index >= 0 else { return nil }
        self.planID = planID
        self.fileIndex = index
    }
}
