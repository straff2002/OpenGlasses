import CryptoKit
import Foundation
@testable import OpenGlasses

/// The managed office folders held in memory, behaving as the Go transport does at the seam: it
/// takes a closed binding object, lists committed jobs that have no receipt, hands out their
/// exact bytes, and publishes a receipt only for a signature the binding's phone application key
/// made over the receipt domain and the payload it offered. It verifies no trust chain, as the
/// real one does not.
actor OfficeManagedFolderMemoryTransport: OfficeManagedFolderTransport {
    struct Start: Equatable, Sendable {
        let bindingJSON: String
        let policy: String
        let lanHint: String
    }

    struct Job: Sendable {
        let messageID: String
        let sequence: Int64
        let file: Data
        /// The exact bytes the phone signs.
        let receiptPayload: Data

        var jobSHA256: String { SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined() }
    }

    enum Failure: Error, Equatable {
        case invalidBinding, alreadyRunning, notOpen, noSuchJob, notThisPhonesSignature
    }

    static let bindingFields: Set<String> = [
        "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID",
        "officeApplicationKey", "phoneApplicationKey"]

    private(set) var starts: [Start] = []
    private(set) var stops = 0
    private(set) var isOpen = false
    /// Published receipts, by message ID: the envelope as it would sit in `records/receipts/`.
    private(set) var receipts: [String: Data] = [:]
    private(set) var publishes = 0
    private var phoneKey: Curve25519.Signing.PublicKey?
    private var jobs: [Job] = []
    private var onStart: (@Sendable () async -> Void)?

    /// Runs while the engine "starts", after the folders are open: where a test changes the world.
    func whenStarting(_ body: @escaping @Sendable () async -> Void) { onStart = body }

    /// A job the transport has verified and committed.
    func commit(_ job: Job) { jobs.append(job) }

    /// The receipt never reached the folder: the job is pending again, as after a failed publish.
    func loseReceipt(messageID: String) { receipts[messageID] = nil }

    func startFolders(bindingJSON: String, policy: String, lanHint: String) async throws {
        guard !isOpen else { throw Failure.alreadyRunning }
        guard let fields = try? JSONSerialization.jsonObject(with: Data(bindingJSON.utf8)) as? [String: Any],
              Set(fields.keys) == Self.bindingFields,
              let generation = fields["generation"] as? Int, generation > 0,
              let office = (fields["officeApplicationKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              office.count == 32,
              let phone = (fields["phoneApplicationKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: phone),
              ["organizationID", "enrolmentID", "officeID", "officeTransportID"]
                .allSatisfy({ (fields[$0] as? String)?.isEmpty == false }) else {
            throw Failure.invalidBinding
        }
        phoneKey = key
        isOpen = true
        starts.append(Start(bindingJSON: bindingJSON, policy: policy, lanHint: lanHint))
        await onStart?()
    }

    func pendingJobs() async throws -> String {
        guard isOpen else { return "[]" }
        let pending = jobs.filter { receipts[$0.messageID] == nil }.map {
            ["messageID": $0.messageID, "sequence": $0.sequence, "jobSHA256": $0.jobSHA256,
             "receiptPayload": $0.receiptPayload.base64EncodedString()] as [String: Any]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: pending), as: UTF8.self)
    }

    func jobFile(messageID: String) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        guard let job = jobs.first(where: { $0.messageID == messageID }) else { throw Failure.noSuchJob }
        return job.file.base64EncodedString()
    }

    func publishReceipt(messageID: String, signatureBase64: String) async throws {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let job = jobs.first(where: { $0.messageID == messageID }) else { throw Failure.noSuchJob }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: OfficeManagedJobReceipt.domain + job.receiptPayload) else {
            throw Failure.notThisPhonesSignature
        }
        publishes += 1
        // Base64 needs no escaping, so the envelope is written out in one fixed order.
        receipts[messageID] = Data(
            #"{"payload":"\#(job.receiptPayload.base64EncodedString())","signature":"\#(signatureBase64)"}"#.utf8)
    }

    func stop() async {
        isOpen = false
        stops += 1
    }
}
