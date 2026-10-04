import CryptoKit
import Foundation

/// Takes the managed jobs the office transport has committed on this phone to the technician.
///
/// For each job the transport lists, its exact bytes go to the existing job-file import. A job
/// file the import would refuse is recorded with a bounded reason and gets no receipt. One it
/// would offer is recorded, its receipt payload is signed with the phone application key under
/// the receipt domain and published, and its review is raised as soon as the review is free. The
/// office's signature on the transport message never skips that review, and the receipt says only
/// that the job is on this phone and ready for it: not that anyone accepted it.
///
/// A job is offered once. If the transport lists it again, because a receipt was not published,
/// it gets the same receipt and no second review. A review that was never answered before the
/// app closed is raised again from the committed bytes; that is the same offer, not a new one.
///
/// No engine, screen or key of its own: everything it touches is a seam, so it runs headless.
@MainActor
final class OfficeManagedJobIntake: ObservableObject {

    /// What became of raising a job's review.
    enum Raised: Equatable, Sendable {
        case raised
        /// The review is showing something else; ask again later.
        case busy
        /// The import refused the file now, though it would have offered it when it arrived.
        case refused(String)
    }

    struct Entry: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// On this phone; the technician has not answered its review yet.
            case awaitingReview
            /// The technician answered: added, updated, or put aside.
            case reviewed
            /// The job-file import refused it. No receipt.
            case refused
        }
        /// SHA-256 of the receipt payload the transport offered, as handed over. It names the
        /// message, the binding it came under and when it was committed, so an exact repeat has
        /// the same value and a job from another office never does.
        let receiptID: String
        let messageID: String
        let sequence: Int64
        let jobSHA256: String
        var state: State
        /// Why it was refused. Bounded.
        var reason: String?
        /// The receipt signature, standard base64, kept so a repeat publishes the same receipt.
        var signature: String?
        var receiptPublished: Bool
    }

    /// The durable record of what was offered and refused. It lives outside the transport.
    struct Ledger: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []
    }

    struct Seams {
        var transport: any OfficeManagedFolderTransport
        /// The existing job-file import's answer for these bytes: why it refuses them, or nil.
        var refusal: @MainActor (Data) -> String?
        /// Raises the existing job review for these bytes under this file name.
        var raise: @MainActor (Data, String) -> Raised
        /// Signs the exact receipt payload with the phone application key under the receipt domain.
        var sign: (Data) async throws -> Data = { try await OfficePhoneIdentity.shared.signManagedJobReceipt($0) }
        var load: () -> Ledger = { Ledger() }
        var save: (Ledger) throws -> Void = { _ in }
    }

    enum State: Equatable, Sendable {
        /// Nothing from the office is waiting on this phone.
        case waitingForOffice
        /// This many jobs are on the phone and waiting for the technician's review.
        case jobReceived(Int)
        /// The latest job from the office could not be added, and none is waiting.
        case jobRefused(String)
    }

    static let maximumReasonCharacters = 200
    static let maximumEntries = 200

    @Published private(set) var state: State = .waitingForOffice
    private(set) var ledger: Ledger

    private let seams: Seams
    private var sweeping = false
    /// Reviews raised since this intake was made, by `receiptID`.
    private var raised: Set<String> = []
    /// The digest of the job file the review is showing now, when it is showing one.
    var reviewShowing: String?

    init(seams: Seams) {
        self.seams = seams
        ledger = seams.load()
        state = Self.state(of: ledger)
    }

    // MARK: - Taking in

    /// One pass over what the transport has committed. Safe to repeat: a pass that is still
    /// running is not joined by a second, and a job already recorded is never offered again.
    /// Throws the first failure of a pass (the transport is closed, the key cannot sign, the
    /// record cannot be saved) after trying every job; the next pass tries again.
    func sweep() async throws {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        var firstFailure: Error?
        let pending = try OfficeManagedFolders.decodePending(try await seams.transport.pendingJobs())
            .sorted { $0.sequence < $1.sequence }
        for job in pending {
            do {
                try await takeIn(job)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        do {
            try await raiseNextReview()
        } catch {
            firstFailure = firstFailure ?? error
        }
        if let firstFailure { throw firstFailure }
    }

    private func takeIn(_ job: OfficeManagedFolders.PendingJob) async throws {
        let id = Self.receiptID(job)
        if let known = ledger.entries.first(where: { $0.receiptID == id }) {
            // An exact repeat: the same receipt, and no second review.
            if known.state != .refused { try await giveReceipt(job, id: id) }
            return
        }
        var entry = Entry(receiptID: id, messageID: job.messageID, sequence: job.sequence,
                          jobSHA256: job.jobSHA256, state: .refused, reason: nil, signature: nil,
                          receiptPublished: false)
        // The receipt offered has to be a receipt, and for this job.
        guard let payload = Data(base64Encoded: job.receiptPayload),
              let receipt = OfficeManagedJobReceipt.payload(payload),
              receipt.messageID == job.messageID, receipt.sequence == job.sequence,
              receipt.jobSHA256 == job.jobSHA256 else {
            entry.reason = "The receipt offered for this job is not a receipt for it."
            try record(entry)
            return
        }
        guard let bytes = Data(base64Encoded: try await seams.transport.jobFile(messageID: job.messageID)),
              Self.sha256(bytes) == job.jobSHA256 else {
            entry.reason = "The job file on this phone is not the one the office sent."
            try record(entry)
            return
        }
        if let reason = seams.refusal(bytes) {
            entry.reason = Self.bounded(reason)
            try record(entry)
            return
        }
        // Recorded before the receipt: a receipt is never given for a job this phone has no
        // record of offering.
        entry.state = .awaitingReview
        try record(entry)
        try await giveReceipt(job, id: id)
    }

    private func giveReceipt(_ job: OfficeManagedFolders.PendingJob, id: String) async throws {
        guard let index = ledger.entries.firstIndex(where: { $0.receiptID == id }),
              let payload = Data(base64Encoded: job.receiptPayload) else { return }
        let signature: String
        if let kept = ledger.entries[index].signature {
            signature = kept
        } else {
            signature = try await seams.sign(payload).base64EncodedString()
            try update(id) { $0.signature = signature }
        }
        try await seams.transport.publishReceipt(messageID: job.messageID, signatureBase64: signature)
        try update(id) { $0.receiptPublished = true }
    }

    /// Raise the review of the lowest-sequence job still waiting for one, if it has not been
    /// raised since launch and the review is free.
    private func raiseNextReview() async throws {
        let waiting = ledger.entries.filter { $0.state == .awaitingReview }.sorted { $0.sequence < $1.sequence }
        // One review at a time: nothing is raised over one of ours that is still open.
        guard let next = waiting.first, !raised.contains(next.receiptID) else { return }
        guard let bytes = Data(base64Encoded: try await seams.transport.jobFile(messageID: next.messageID)),
              Self.sha256(bytes) == next.jobSHA256 else {
            try update(next.receiptID) {
                $0.state = .refused
                $0.reason = "The job file on this phone is not the one the office sent."
            }
            return
        }
        switch seams.raise(bytes, Self.fileName(sequence: next.sequence)) {
        case .raised:
            raised.insert(next.receiptID)
        case .busy:
            break
        case .refused(let reason):
            try update(next.receiptID) {
                $0.state = .refused
                $0.reason = Self.bounded(reason)
            }
        }
    }

    /// The technician answered (or put aside) the review of the job file with this digest.
    func reviewEnded(jobSHA256: String) {
        for entry in ledger.entries
        where entry.jobSHA256 == jobSHA256 && entry.state == .awaitingReview && raised.contains(entry.receiptID) {
            try? update(entry.receiptID) { $0.state = .reviewed }
        }
    }

    // MARK: - The record

    private func record(_ entry: Entry) throws {
        var next = ledger
        next.entries.append(entry)
        // Bounded: the oldest settled entries go first. One still owed a review or a receipt stays.
        while next.entries.count > Self.maximumEntries,
              let settled = next.entries.firstIndex(where: {
                  $0.state == .refused || ($0.state == .reviewed && $0.receiptPublished)
              }) {
            next.entries.remove(at: settled)
        }
        try commit(next)
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) throws {
        guard let index = ledger.entries.firstIndex(where: { $0.receiptID == id }) else { return }
        var next = ledger
        change(&next.entries[index])
        try commit(next)
    }

    /// Saved first: what is in memory is never ahead of what is on disk.
    private func commit(_ next: Ledger) throws {
        try seams.save(next)
        ledger = next
        state = Self.state(of: next)
    }

    // MARK: - Pure

    static func receiptID(_ job: OfficeManagedFolders.PendingJob) -> String {
        sha256(Data(job.receiptPayload.utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bounded(_ reason: String) -> String {
        String(reason.prefix(maximumReasonCharacters))
    }

    /// The name the review shows for a job that came over the office connection.
    static func fileName(sequence: Int64) -> String {
        "office-job-\(sequence).ogjob"
    }

    static func state(of ledger: Ledger) -> State {
        let waiting = ledger.entries.filter { $0.state == .awaitingReview }.count
        if waiting > 0 { return .jobReceived(waiting) }
        if let last = ledger.entries.last, last.state == .refused {
            return .jobRefused(last.reason ?? "")
        }
        return .waitingForOffice
    }

    /// The words for each state. Nil when nothing is shown: while nothing has arrived, the
    /// connection's own line says whether the phone is waiting for the office. A job is "received"
    /// when it is on this phone and ready for review; nothing here says sent or delivered.
    static func status(_ state: State) -> OfficeFieldConnectionPolicy.Status? {
        switch state {
        case .waitingForOffice:
            return nil
        case .jobReceived(let count):
            return .init(title: "Job received",
                         detail: count == 1 ? "A job from the office is ready for your review."
                                            : "\(count) jobs from the office are ready for your review.",
                         systemImage: "tray.and.arrow.down")
        case .jobRefused(let reason):
            return .init(title: "A job from the office couldn't be added",
                         detail: reason.isEmpty ? nil : reason,
                         systemImage: "exclamationmark.triangle")
        }
    }
}
