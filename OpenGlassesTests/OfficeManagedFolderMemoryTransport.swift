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
        case notThisPhonesReport, anotherReportUnderThatOperation, noSuchAttachment, notTheBytesNamed
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

    // MARK: Reports

    /// What sits in `records/reports/` and `records/attachments/`, and the receipts the office
    /// has put in `control/receipts/`, by report identifier.
    private(set) var reports: [String: Data] = [:]
    private(set) var reportRecords: [String: Data] = [:]
    private(set) var reportManifests: [String: Data] = [:]
    private(set) var attachments: [String: Data] = [:]
    private(set) var reportPublishes = 0
    private(set) var withdrawnReports: [String] = []
    private var receiptFiles: [String: [String: Data]] = [:]

    /// The office answers: a receipt under the name its outcome has.
    func put(receipt: Data, reportID: String, stage: String) {
        receiptFiles[reportID, default: [:]][stage] = receipt
    }

    func publishReport(payloadBase64: String, signatureBase64: String, recordBase64: String,
                       manifestBase64: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let payload = Data(base64Encoded: payloadBase64),
              let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              let record = Data(base64Encoded: recordBase64),
              let manifest = Data(base64Encoded: manifestBase64),
              phoneKey.isValidSignature(signature, for: OfficeReport.reportDomain + payload),
              let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let reportID = fields["reportID"] as? String,
              fields["recordSHA256"] as? String == OfficeReport.digest(record),
              fields["manifestSHA256"] as? String == OfficeReport.digest(manifest) else {
            throw Failure.notThisPhonesReport
        }
        // A published name keeps its bytes: the same report again is the file already there.
        if let existing = reports[reportID] {
            guard reportRecords[reportID] == record, reportManifests[reportID] == manifest else {
                throw Failure.anotherReportUnderThatOperation
            }
            return String(decoding: existing, as: UTF8.self)
        }
        reportPublishes += 1
        let envelope = OfficeReport.envelopeBytes(payload: payload, signature: signature)
        reports[reportID] = envelope
        reportRecords[reportID] = record
        reportManifests[reportID] = manifest
        return String(decoding: envelope, as: UTF8.self)
    }

    func publishReportAttachment(sha256: String, path: String) async throws {
        guard isOpen else { throw Failure.notOpen }
        guard reportManifests.values.contains(where: {
            String(decoding: $0, as: UTF8.self).contains(#""sha256":"\#(sha256)""#)
        }) else { throw Failure.noSuchAttachment }
        if attachments[sha256] != nil { return }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
              OfficeReport.digest(bytes) == sha256 else { throw Failure.notTheBytesNamed }
        attachments[sha256] = bytes
    }

    func reportReceipts() async throws -> String {
        guard isOpen else { return "[]" }
        var listed: [[String: String]] = []
        for reportID in reports.keys.sorted() {
            for stage in ["pending", "record", "full"] {
                if let receipt = receiptFiles[reportID]?[stage] {
                    listed.append(["reportID": reportID, "stage": stage,
                                   "envelope": receipt.base64EncodedString()])
                }
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: listed), as: UTF8.self)
    }

    func withdrawReport(reportID: String) async throws {
        guard isOpen else { throw Failure.notOpen }
        guard reports[reportID] != nil else { return }
        let named = { (manifest: Data?) in String(decoding: manifest ?? Data(), as: UTF8.self) }
        let gone = named(reportManifests[reportID])
        reports[reportID] = nil
        reportRecords[reportID] = nil
        reportManifests[reportID] = nil
        // An attachment another published report still names stays.
        let stillNamed = reportManifests.values.map { named($0) }.joined()
        for digest in attachments.keys where gone.contains(digest) && !stillNamed.contains(digest) {
            attachments[digest] = nil
        }
        withdrawnReports.append(reportID)
    }

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
