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
    /// `officeID`, `generation`, `officeTransportID`, `officeApplicationKey` and
    /// `phoneApplicationKey` (the keys standard base64). The transport verifies none of that
    /// chain: only `OfficePairingService.openFoldersWithApprovedOffice` may call this, with a
    /// binding it has rechecked at that moment.
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

    enum DecodingFailure: Error, Equatable {
        case malformed
    }

    static func decodePending(_ json: String) throws -> [PendingJob] {
        guard let pending = try? JSONDecoder().decode([PendingJob].self, from: Data(json.utf8)) else {
            throw DecodingFailure.malformed
        }
        return pending
    }
}
