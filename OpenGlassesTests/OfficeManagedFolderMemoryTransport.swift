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
        case invalidBulkRequest, noSuchBulkContent, noSuchAssignment
        case noSuchUpdate
        case notThisPhonesManifest, notTheBundlesBytes, anotherManifestUnderThatBundle, noSuchRecording
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

    // MARK: Bulk content

    /// What sits in `control/publishers/` and `control/assignments/`, by identifier, and what the
    /// office has put in the `bulk` folder, by name.
    private(set) var grantFiles: [String: Data] = [:]
    private(set) var assignmentFiles: [String: Data] = [:]
    private(set) var bulkOffered: [String: Data] = [:]
    /// What the phone has asked for, whether the folder is paused, and what was taken in.
    private(set) var bulkWanted: [(kind: String, sha256: String, bytes: Int)] = []
    private(set) var bulkPaused = true
    private(set) var bulkTaken: [String: URL] = [:]
    private(set) var assignmentReceipts: [String: Data] = [:]
    private var assignmentReceiptPayloads: [String: Data] = [:]
    /// This phone's transport identity, which the real transport knows for itself.
    var phoneTransportID = "A44GCYW-HLGLMZV-EG2RHLW-YRQ773E-7GZUZMH-26RQHUT-MGGFBAI-JF7G6AW"

    func put(grant: Data, id: String) { grantFiles[id] = grant }
    func put(assignment: Data, id: String) { assignmentFiles[id] = assignment }
    /// The office puts a file in the `bulk` folder under a name.
    func offer(bulk name: String, _ data: Data) { bulkOffered[name] = data }

    func bulkPending() async throws -> String {
        let pending: [String: Any] = isOpen
            ? ["grants": Self.listing(grantFiles), "assignments": Self.listing(assignmentFiles)]
            : ["grants": [], "assignments": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: pending), as: UTF8.self)
    }

    func setBulkWanted(_ wantedJSON: String) async throws {
        guard isOpen else { throw Failure.notOpen }
        guard let items = try? JSONSerialization.jsonObject(with: Data(wantedJSON.utf8)) as? [[String: Any]] else {
            throw Failure.invalidBulkRequest
        }
        var next: [(kind: String, sha256: String, bytes: Int)] = []
        for item in items {
            guard let kind = item["kind"] as? String, ["vault", "attachment"].contains(kind),
                  let sha256 = item["sha256"] as? String, sha256.utf8.count == 64,
                  let bytes = item["bytes"] as? Int, bytes > 0 else { throw Failure.invalidBulkRequest }
            next.append((kind, sha256, bytes))
        }
        bulkWanted = next
        for digest in bulkTaken.keys where !next.contains(where: { $0.sha256 == digest }) {
            if let file = bulkTaken[digest] { try? FileManager.default.removeItem(at: file) }
            bulkTaken[digest] = nil
        }
    }

    func bulkStatus() async throws -> String {
        guard isOpen else { return "[]" }
        var status: [[String: String]] = []
        for item in bulkWanted {
            let name = item.kind == "vault" ? "vaults/\(item.sha256).zip" : "attachments/\(item.sha256)"
            var state = "waiting"
            if bulkTaken[item.sha256] != nil {
                state = "ready"
            } else if let bytes = bulkOffered[name] {
                state = "offered"
                // A paused folder takes nothing; an unpaused one takes only the exact bytes.
                if !bulkPaused, bytes.count == item.bytes, OfficeReport.digest(bytes) == item.sha256 {
                    let file = FileManager.default.temporaryDirectory
                        .appendingPathComponent("memory-bulk-\(UUID().uuidString)")
                    try bytes.write(to: file)
                    bulkTaken[item.sha256] = file
                    state = "ready"
                }
            }
            status.append(["kind": item.kind, "sha256": item.sha256, "state": state])
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: status), as: UTF8.self)
    }

    func bulkFile(sha256: String) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        guard let file = bulkTaken[sha256] else { throw Failure.noSuchBulkContent }
        return file.path
    }

    func setBulkPaused(_ paused: Bool) async throws {
        guard isOpen else { throw Failure.notOpen }
        bulkPaused = paused
    }

    func assignmentReceiptPayload(assignmentID: String, outcome: String, at: Int64) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        let key = "\(assignmentID).\(outcome)"
        if let built = assignmentReceiptPayloads[key] { return built.base64EncodedString() }
        guard let envelope = assignmentFiles[assignmentID],
              let fields = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let payload = (fields["payload"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let a = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Failure.noSuchAssignment
        }
        func text(_ name: String) -> String { a[name] as? String ?? "" }
        func number(_ name: String) -> Int64 { (a[name] as? NSNumber)?.int64Value ?? 0 }
        // The order the transport writes a receipt in. Every value here is plain ASCII.
        let members: [String] = [
            #""version":1"#, #""kind":"avenkin.manual-assignment-receipt""#,
            #""assignmentID":"\#(assignmentID)""#, #""assignmentSHA256":"\#(OfficeReport.digest(payload))""#,
            #""organizationID":"\#(text("organizationID"))""#, #""enrolmentID":"\#(text("enrolmentID"))""#,
            #""officeID":"\#(text("officeID"))""#, #""generation":\#(number("generation"))"#,
            #""phoneTransportID":"\#(phoneTransportID)""#, #""setID":"\#(text("setID"))""#,
            #""sequence":\#(number("sequence"))"#, #""archiveSHA256":"\#(text("archiveSHA256"))""#,
            #""outcome":"\#(outcome)""#, #""at":\#(at)"#,
        ]
        let built = Data(("{" + members.joined(separator: ",") + "}").utf8)
        assignmentReceiptPayloads[key] = built
        return built.base64EncodedString()
    }

    func publishAssignmentReceipt(assignmentID: String, outcome: String,
                                  signatureBase64: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        let key = "\(assignmentID).\(outcome)"
        guard let payload = assignmentReceiptPayloads[key] else { throw Failure.noSuchAssignment }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: OfficeBulk.receiptDomain + payload) else {
            throw Failure.notThisPhonesSignature
        }
        if let published = assignmentReceipts[key] { return String(decoding: published, as: UTF8.self) }
        let envelope = Self.sealed(payload, signatureBase64)
        assignmentReceipts[key] = envelope
        return String(decoding: envelope, as: UTF8.self)
    }

    // MARK: Job updates

    /// What sits in `control/updates/`, by identifier, and the receipts published for them.
    private(set) var updateFiles: [String: Data] = [:]
    private(set) var updateReceipts: [String: Data] = [:]
    private var updateReceiptPayloads: [String: Data] = [:]

    func put(update: Data, id: String) { updateFiles[id] = update }
    /// The office takes an update out of the folder.
    func remove(update id: String) { updateFiles[id] = nil }

    func jobUpdatesPending() async throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: isOpen ? Self.listing(updateFiles) : []),
               as: UTF8.self)
    }

    func jobUpdateReceiptPayload(updateID: String, jobState: String, at: Int64) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        if let built = updateReceiptPayloads[updateID] { return built.base64EncodedString() }
        guard let envelope = updateFiles[updateID],
              let fields = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
              let payload = (fields["payload"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let u = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Failure.noSuchUpdate
        }
        func text(_ name: String) -> String { u[name] as? String ?? "" }
        func number(_ name: String) -> Int64 { (u[name] as? NSNumber)?.int64Value ?? 0 }
        // The order the transport writes a receipt in. Every value here is plain ASCII.
        let members: [String] = [
            #""version":1"#, #""kind":"avenkin.job-update-receipt""#,
            #""updateID":"\#(updateID)""#, #""updateSHA256":"\#(OfficeReport.digest(payload))""#,
            #""organizationID":"\#(text("organizationID"))""#, #""enrolmentID":"\#(text("enrolmentID"))""#,
            #""officeID":"\#(text("officeID"))""#, #""generation":\#(number("generation"))"#,
            #""phoneTransportID":"\#(phoneTransportID)""#, #""jobID":"\#(text("jobID"))""#,
            #""sequence":\#(number("sequence"))"#, #""outcome":"received""#,
            #""jobState":"\#(jobState)""#, #""receivedAt":\#(at)"#,
        ]
        let built = Data(("{" + members.joined(separator: ",") + "}").utf8)
        updateReceiptPayloads[updateID] = built
        return built.base64EncodedString()
    }

    func publishJobUpdateReceipt(updateID: String, signatureBase64: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let payload = updateReceiptPayloads[updateID] else { throw Failure.noSuchUpdate }
        guard let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: Data("Avenkin.JobUpdateReceipt.v1\0".utf8) + payload) else {
            throw Failure.notThisPhonesSignature
        }
        if let published = updateReceipts[updateID] { return String(decoding: published, as: UTF8.self) }
        let envelope = Self.sealed(payload, signatureBase64)
        updateReceipts[updateID] = envelope
        return String(decoding: envelope, as: UTF8.self)
    }

    // MARK: Recorded-job bundles

    /// One bundle in `records/recordings/`: what its manifest lists, and what has been published.
    struct Recording {
        var envelope: Data
        var manifestSHA256: String
        /// Path → (digest, bytes), as the manifest lists them.
        var files: [String: (sha256: String, bytes: Int)]
        var published: [String: Data]
        /// Out of `records` and not served; what the office says later is still listed.
        var withdrawn = false
    }

    private(set) var recordings: [String: Recording] = [:]
    private(set) var withdrawnRecordings: [String] = []
    private(set) var recordingChunkPublishes = 0
    private var recordingStatusFiles: [String: [String: Data]] = [:]
    /// The published paths the office has taken, by bundle: what the test's office holds.
    private var officeHolds: [String: Set<String>] = [:]

    /// The office takes everything published so far for a bundle, or just the paths given.
    func officeTakes(_ bundleID: String, paths: Set<String>? = nil) {
        guard let recording = recordings[bundleID] else { return }
        officeHolds[bundleID, default: []].formUnion(paths ?? Set(recording.published.keys).union(["manifest.envelope.json"]))
    }

    /// The office says something about a bundle, under the name that status has.
    func put(recordingStatus: Data, bundleID: String, status: String) {
        recordingStatusFiles[bundleID, default: [:]][status] = recordingStatus
    }

    func publishRecordingManifest(payloadBase64: String, signatureBase64: String, timelinePath: String,
                                  transcriptPath: String) async throws -> String {
        guard isOpen, let phoneKey else { throw Failure.notOpen }
        guard let payload = Data(base64Encoded: payloadBase64),
              let signature = Data(base64Encoded: signatureBase64), signature.count == 64,
              phoneKey.isValidSignature(signature, for: Data("Avenkin.RecordingBundle.v1\0".utf8) + payload),
              let manifest = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let bundleID = manifest["bundleID"] as? String,
              let listed = manifest["files"] as? [[String: Any]] else { throw Failure.notThisPhonesManifest }
        var files: [String: (sha256: String, bytes: Int)] = [:]
        for file in listed {
            guard let path = file["path"] as? String, let sha256 = file["sha256"] as? String,
                  let bytes = file["bytes"] as? Int else { throw Failure.notThisPhonesManifest }
            files[path] = (sha256, bytes)
        }
        let digest = OfficeReport.digest(payload)
        if let held = recordings[bundleID] {
            guard held.manifestSHA256 == digest else { throw Failure.anotherManifestUnderThatBundle }
            if !held.withdrawn { return String(decoding: held.envelope, as: UTF8.self) }
        }
        var published: [String: Data] = [:]
        for (name, path) in [("timeline.json", timelinePath), ("transcript.json", transcriptPath)] {
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), let stated = files[name],
                  bytes.count == stated.bytes, OfficeReport.digest(bytes) == stated.sha256 else {
                throw Failure.notTheBundlesBytes
            }
            published[name] = bytes
        }
        let envelope = Self.sealed(payload, signatureBase64)
        recordings[bundleID] = Recording(envelope: envelope, manifestSHA256: digest, files: files, published: published)
        officeHolds[bundleID] = nil
        return String(decoding: envelope, as: UTF8.self)
    }

    func publishRecordingChunk(bundleID: String, sha256: String, path: String) async throws {
        guard isOpen else { throw Failure.notOpen }
        let name = "media/\(sha256).chunk"
        guard var recording = recordings[bundleID], !recording.withdrawn, let stated = recording.files[name] else {
            throw Failure.noSuchRecording
        }
        if recording.published[name] != nil { return }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)), bytes.count == stated.bytes,
              OfficeReport.digest(bytes) == sha256 else { throw Failure.notTheBundlesBytes }
        recording.published[name] = bytes
        recordings[bundleID] = recording
        recordingChunkPublishes += 1
    }

    func recordingProgress(bundleID: String) async throws -> String {
        guard isOpen else { throw Failure.notOpen }
        guard let recording = recordings[bundleID], !recording.withdrawn else { throw Failure.noSuchRecording }
        let held = officeHolds[bundleID] ?? []
        let total = recording.files.values.reduce(0) { $0 + $1.bytes }
        let published = recording.published.values.reduce(0) { $0 + $1.count }
        let served = recording.published.filter { held.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        let all = held.contains("manifest.envelope.json") && recording.files.keys.allSatisfy {
            recording.published[$0] != nil && held.contains($0)
        }
        let progress: [String: Any] = ["bundleID": bundleID, "totalBytes": total, "publishedBytes": published,
                                       "servedBytes": served, "allServed": all]
        return String(decoding: try JSONSerialization.data(withJSONObject: progress), as: UTF8.self)
    }

    func recordingStatuses() async throws -> String {
        guard isOpen else { return "[]" }
        var listed: [[String: String]] = []
        for bundleID in recordings.keys.sorted() {
            for (status, envelope) in (recordingStatusFiles[bundleID] ?? [:]).sorted(by: { $0.key < $1.key }) {
                listed.append(["bundleID": bundleID, "status": status, "envelope": envelope.base64EncodedString()])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: listed), as: UTF8.self)
    }

    func withdrawRecording(bundleID: String, forget: Bool) async throws {
        guard isOpen else { throw Failure.notOpen }
        guard recordings[bundleID] != nil else { return }
        if forget {
            recordings[bundleID] = nil
            recordingStatusFiles[bundleID] = nil
        } else {
            recordings[bundleID]?.withdrawn = true
            recordings[bundleID]?.published = [:]
        }
        officeHolds[bundleID] = nil
        withdrawnRecordings.append(bundleID)
    }

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
