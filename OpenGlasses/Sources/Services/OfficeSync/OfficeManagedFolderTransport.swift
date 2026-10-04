import Foundation

/// The seam between the app and the managed office folders (Contracts/office-folders.md): the
/// `control` folder this phone only receives and the `records` folder it only sends. Each method
/// mirrors one function of the gomobile package `mobilecore` and returns exactly the text that
/// function returns. Verifying a managed job against the binding, committing its bytes and the
/// outbound guard live behind it, in Go; the trust chain, the technician's review and the phone
/// application key stay on the Swift side.
///
/// The app's implementation is `OfficeManagedFolderMobilecoreTransport`, in the opt-in office
/// transport build only. Tests drive it through an in-memory one.
protocol OfficeManagedFolderTransport: Sendable {
    /// `StartManagedOfficeFolders`: opens the pinned managed connection with the two folders the
    /// binding calls for. `bindingJSON` is a closed object with `organizationID`, `enrolmentID`,
    /// `officeID`, `generation`, `officeTransportID`, `officeApplicationKey`,
    /// `phoneApplicationKey`, `profileID`, `bindingSHA256` and `administratorKey` (the keys
    /// standard base64; the last three are what check-in, renewal and removal are read against).
    /// The transport verifies none of that chain: only
    /// `OfficePairingService.openFoldersWithApprovedOffice` may call this, with a binding it has
    /// rechecked at that moment.
    func startFolders(bindingJSON: String, policy: String, lanHint: String) async throws

    /// `ManagedJobsPending`: the jobs this phone has verified and committed and not yet given a
    /// receipt for, as a JSON array of `OfficeManagedFolders.PendingJob`.
    func pendingJobs() async throws -> String

    /// `ManagedJobFile`: the committed job-file bytes of one managed job, standard base64.
    /// Committing a job is not accepting it.
    func jobFile(messageID: String) async throws -> String

    /// `PublishManagedJobReceipt`: publishes the receipt for one committed job. `signatureBase64`
    /// is the phone application key's signature over the receipt domain followed by the receipt
    /// payload `pendingJobs` gave. A signature that is not this phone's publishes nothing.
    func publishReceipt(messageID: String, signatureBase64: String) async throws

    /// `ManagedCheckInPending`: what the office has put in `control/checkin/` and
    /// `control/removal/` that reads as its own message under the binding handed over, as a JSON
    /// `OfficeManagedFolders.CheckInPending`. Listing is not acting: each is verified again here
    /// before anything is answered, committed or revoked.
    func checkInPending() async throws -> String

    /// `ManagedCheckInPayload`: the exact bytes (standard base64) of the check-in that answers
    /// the live challenge, for the phone application key to sign. Asking again for the same
    /// challenge returns the same bytes, with the same nonce.
    func checkInPayload(challengeID: String, leaseRenewBy: Int64, appVersion: String,
                        appBuild: String) async throws -> String

    /// `PublishManagedCheckIn`: publishes the check-in at `records/checkin/` and returns the
    /// exact envelope published. A signature that is not this phone's publishes nothing.
    func publishCheckIn(challengeID: String, signatureBase64: String) async throws -> String

    /// `ManagedRemovalReceiptPayload`: the exact bytes (standard base64) of the receipt for a
    /// removal, for the phone application key to sign. `actedAt` is when the enrolment was marked
    /// revoked; asking again returns the same bytes.
    func removalReceiptPayload(removalID: String, actedAt: Int64) async throws -> String

    /// `PublishManagedRemovalReceipt`: publishes the receipt at `records/removal/` and returns
    /// the exact envelope published.
    func publishRemovalReceipt(removalID: String, signatureBase64: String) async throws -> String

    /// `PublishManagedReport`: publishes one report at `records/reports/` with the record and the
    /// manifest it names, and returns the exact envelope published. Each argument is standard
    /// base64. The transport checks all of it as the office will; publishing the same report again
    /// returns the envelope already there.
    func publishReport(payloadBase64: String, signatureBase64: String, recordBase64: String,
                       manifestBase64: String) async throws -> String

    /// `PublishManagedReportAttachment`: publishes one attachment a published report names, at
    /// `records/attachments/<sha256>`, from a file in the app's own storage that holds exactly the
    /// bytes the manifest gave.
    func publishReportAttachment(sha256: String, path: String) async throws

    /// `ManagedReportReceipts`: the office's receipts for the reports this phone has published,
    /// as a JSON array of `OfficeManagedFolders.ReportReceipt`. Listing is not acting.
    func reportReceipts() async throws -> String

    /// `WithdrawManagedReport`: takes a published report out of `records`, with the files no
    /// other published report names.
    func withdrawReport(reportID: String) async throws

    /// `Stop`: closes the connection and its folders. What was committed stays committed.
    func stop() async
}

/// What the transport's JSON answers mean on the phone. Decoding only.
enum OfficeManagedFolders {
    /// A committed job that has no published receipt yet.
    struct PendingJob: Decodable, Equatable, Sendable {
        let messageID: String
        let sequence: Int64
        let jobSHA256: String
        /// The exact bytes to sign with the phone application key, standard base64. The signature
        /// is over the receipt domain followed by these bytes.
        let receiptPayload: String
    }

    /// One file from `control`, as the transport read it.
    struct PendingEnvelope: Decodable, Equatable, Sendable {
        /// The identifier in the file's name: a challenge's or a removal's.
        let id: String
        /// The exact bytes of the file, standard base64.
        let envelope: String
    }

    /// What has arrived for check-in, renewal and removal.
    struct CheckInPending: Decodable, Equatable, Sendable {
        let challenges: [PendingEnvelope]
        let results: [PendingEnvelope]
        let removals: [PendingEnvelope]
    }

    /// One receipt from `control/receipts/`, as the transport read it.
    struct ReportReceipt: Decodable, Equatable, Sendable {
        let reportID: String
        /// The word in the file's name: `pending`, `record` or `full`.
        let stage: String
        /// The exact bytes of the file, standard base64.
        let envelope: String
    }

    enum DecodingFailure: Error, Equatable {
        case malformed
    }

    static func decodePending(_ json: String) throws -> [PendingJob] {
        guard let pending = try? JSONDecoder().decode([PendingJob].self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return pending
    }

    static func decodeReportReceipts(_ json: String) throws -> [ReportReceipt] {
        guard let receipts = try? JSONDecoder().decode([ReportReceipt].self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return receipts
    }

    static func decodeCheckInPending(_ json: String) throws -> CheckInPending {
        guard let pending = try? JSONDecoder().decode(CheckInPending.self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return pending
    }
}
