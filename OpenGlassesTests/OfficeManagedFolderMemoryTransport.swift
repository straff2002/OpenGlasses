import CryptoKit
import Foundation
@testable import OpenGlasses

/// The managed office folders held in memory, behaving as the Go transport does at the seam: it
/// takes a closed binding object, lists committed jobs that have no receipt, hands out their
/// exact bytes, and publishes a receipt only for a signature the binding's phone application key
/// made over the receipt domain and the payload it offered. For check-in it lists whatever was
/// put in `control` (the real one lists only what reads as its own message; the phone's verifier
/// is what these tests are about), builds a check-in or removal-receipt payload once per
/// identifier, and publishes only under this phone's signature. It verifies no trust chain, as
/// the real one does not.
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
        case noSuchChallenge, noSuchRemoval
    }

    static let bindingFields: Set<String> = [
        "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID",
        "officeApplicationKey", "phoneApplicationKey", "profileID", "bindingSHA256", "administratorKey"]

    /// The earlier form, without what check-in is read against: managed jobs only, as the real
    /// transport takes it.
    static let jobBindingFields: Set<String> = [
        "organizationID", "enrolmentID", "officeID", "generation", "officeTransportID",
        "officeApplicationKey", "phoneApplicationKey"]

    // MARK: Check-in, renewal and removal

    /// What sits in `control/checkin/` and `control/removal/`, by the identifier in its name.
    private(set) var challenges: [String: Data] = [:]
    private(set) var results: [String: Data] = [:]
    private(set) var removals: [String: Data] = [:]
    /// The check-in payload built for each challenge, and the envelope published for it.
    private(set) var checkInPayloads: [String: Data] = [:]
    private(set) var checkIns: [String: Data] = [:]
    private(set) var checkInPublishes = 0
    private(set) var removalReceiptPayloads: [String: Data] = [:]
    private(set) var removalReceipts: [String: Data] = [:]

    func put(challenge: Data, id: String) { challenges[id] = challenge }
    func put(result: Data, id: String) { results[id] = result }
    func put(removal: Data, id: String) { removals[id] = removal }
    func withdraw(challenge id: String) { challenges[id] = nil }
    func withdraw(result id: String) { results[id] = nil }
    /// The payload the transport will offer for a challenge, in place of one with a random nonce.
    func offer(checkInPayload: Data, for id: String) { checkInPayloads[id] = checkInPayload }
    /// The transport lost its record of a check-in, as after its private state was erased.
    func loseCheckIn(for id: String) {
        checkInPayloads[id] = nil
        checkIns[id] = nil
    }

    private static func decodedPayload(_ envelope: Data) -> [String: Any]? {
        guard let fields = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let payload = (fields["payload"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
        return try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
    }

    private static func sealed(_ payload: Data, _ signatureBase64: String) -> Data {
        // Base64 needs no escaping, so the envelope is written out in one fixed order.
        Data(#"{"payload":"\#(payload.base64EncodedString())","signature":"\#(signatureBase64)"}"#.utf8)
    }

    private static func listing(_ files: [String: Data]) -> [[String: String]] {
        files.keys.sorted().map { ["id": $0, "envelope": files[$0]!.base64EncodedString()] }
    }

    func checkInPending() async throws -> String {
        let pending: [String: Any] = isOpen
            ? ["challenges": Self.listing(challenges), "results": Self.listing(results),
               "removals": Self.listing(removals)]
            : ["challenges": [], "results": [], "removals": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: pending), as: UTF8.self)
    }

    func checkInPayload(challengeID: String, leaseRenewBy: Int64, appVersion: String,
                        appBuild: String) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        if let built = checkInPayloads[challengeID] { return built.base64EncodedString() }
        guard let envelope = challenges[challengeID], let c = Self.decodedPayload(envelope) else {
            throw Failure.noSuchChallenge
        }
        var random = SystemRandomNumberGenerator()
        let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) })
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: envelope).map { String(format: "%02x", $0) }.joined()
        // The order the transport writes a check-in in. Every value here is plain ASCII.
        func text(_ key: String) -> String { c[key] as? String ?? "" }
        let generation = (c["generation"] as? NSNumber)?.int64Value ?? 0
        let members: [String] = [
            #""version":1"#, #""kind":"avenkin.office-check-in""#,
            #""challengeID":"\#(challengeID)""#, #""challengeSHA256":"\#(digest)""#, #""nonce":"\#(nonce)""#,
            #""organizationID":"\#(text("organizationID"))""#, #""enrolmentID":"\#(text("enrolmentID"))""#,
            #""officeID":"\#(text("officeID"))""#, #""phoneTransportID":"\#(text("phoneTransportID"))""#,
            #""generation":\#(generation)"#, #""bindingSHA256":"\#(text("bindingSHA256"))""#,
            #""leaseRenewBy":\#(leaseRenewBy)"#, #""appVersion":"\#(appVersion)""#,
            #""appBuild":"\#(appBuild)""#, #""createdAt":\#(leaseRenewBy)"#,
        ]
        let payload = Data(("{" + members.joined(separator: ",") + "}").utf8)
        checkInPayloads[challengeID] = payload
        return payload.base64EncodedString()
    }

    func publishCheckIn(challengeID: String, signatureBase64: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let payload = checkInPayloads[challengeID] else { throw Failure.noSuchChallenge }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: OfficeCheckIn.checkInDomain + payload) else {
            throw Failure.notThisPhonesSignature
        }
        // A published name keeps its bytes.
        if let published = checkIns[challengeID] { return String(decoding: published, as: UTF8.self) }
        checkInPublishes += 1
        let envelope = Self.sealed(payload, signatureBase64)
        checkIns[challengeID] = envelope
        return String(decoding: envelope, as: UTF8.self)
    }

    func removalReceiptPayload(removalID: String, actedAt: Int64) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        if let built = removalReceiptPayloads[removalID] { return built.base64EncodedString() }
        guard let envelope = removals[removalID], let r = Self.decodedPayload(envelope) else {
            throw Failure.noSuchRemoval
        }
        let digest = SHA256.hash(data: envelope).map { String(format: "%02x", $0) }.joined()
        func text(_ key: String) -> String { r[key] as? String ?? "" }
        let members: [String] = [
            #""version":1"#, #""kind":"avenkin.office-removal-receipt""#,
            #""removalID":"\#(removalID)""#, #""removalSHA256":"\#(digest)""#,
            #""organizationID":"\#(text("organizationID"))""#, #""enrolmentID":"\#(text("enrolmentID"))""#,
            #""phoneTransportID":"\#(text("phoneTransportID"))""#, #""actedAt":\#(actedAt)"#,
        ]
        let payload = Data(("{" + members.joined(separator: ",") + "}").utf8)
        removalReceiptPayloads[removalID] = payload
        return payload.base64EncodedString()
    }

    func publishRemovalReceipt(removalID: String, signatureBase64: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let payload = removalReceiptPayloads[removalID] else { throw Failure.noSuchRemoval }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: OfficeCheckIn.removalReceiptDomain + payload) else {
            throw Failure.notThisPhonesSignature
        }
        if let published = removalReceipts[removalID] { return String(decoding: published, as: UTF8.self) }
        let envelope = Self.sealed(payload, signatureBase64)
        removalReceipts[removalID] = envelope
        return String(decoding: envelope, as: UTF8.self)
    }

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
              Set(fields.keys) == Self.bindingFields || Set(fields.keys) == Self.jobBindingFields,
              let generation = fields["generation"] as? Int, generation > 0,
              let office = (fields["officeApplicationKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              office.count == 32,
              let phone = (fields["phoneApplicationKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: phone),
              Self.jobBindingFields.subtracting(["generation"]).union(Set(fields.keys))
                .allSatisfy({ (fields[$0] as? String)?.isEmpty == false || $0 == "generation" }),
              fields["administratorKey"] == nil
                || (fields["administratorKey"] as? String).flatMap({ Data(base64Encoded: $0) })?.count == 32,
              fields["bindingSHA256"] == nil || (fields["bindingSHA256"] as? String)?.utf8.count == 64 else {
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
