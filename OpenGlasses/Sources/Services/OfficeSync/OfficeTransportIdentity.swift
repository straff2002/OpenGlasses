import Foundation

#if AVENKIN_OFFICE_TRANSPORT
import Mobilecore
#endif

/// The phone's Syncthing certificate identity, read from the same embedded engine that will
/// eventually connect. Preparing it creates no peer, folder, listener or network request.
actor OfficeTransportIdentity {
    enum Refusal: Error, Equatable {
        case unavailable
        case emptyIdentity
    }

    static let shared = OfficeTransportIdentity()

    #if AVENKIN_OFFICE_TRANSPORT
    private var client: MobilecoreClient?
    #endif

    func deviceID() throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        return try preparedClient().deviceID()
        #else
        throw Refusal.unavailable
        #endif
    }

    /// Whether this build links the embedded engine at all.
    static var isAvailable: Bool {
        #if AVENKIN_OFFICE_TRANSPORT
        return true
        #else
        return false
        #endif
    }

    /// Handshake-only: the embedded engine pins the office certificate and creates no folder or
    /// listener. `policy` is the vendor-signed profile's; `lanHint` is "" or a private-LAN
    /// `tcp://a.b.c.d:port`, which `privateLan` requires. The caller must reverify the saved
    /// organisation approval before invoking this method.
    func startManagedOffice(transportID: String, policy: OfficePairingService.TransportPolicy,
                            lanHint: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().startManagedOfficeRoute(transportID, policy: policy.rawValue, lanHint: lanHint)
        #else
        throw Refusal.unavailable
        #endif
    }

    /// The managed connection with its two folders (`OfficeManagedFolderTransport`): `control`,
    /// which this phone only receives, and `records`, which it only sends. The engine verifies
    /// nothing of the binding's chain; only `OfficePairingService.openFoldersWithApprovedOffice`
    /// calls this, with a binding it has rechecked at that moment.
    func startManagedOfficeFolders(bindingJSON: String, policy: String, lanHint: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().startManagedOfficeFolders(bindingJSON, policy: policy, lanHint: lanHint)
        #else
        throw Refusal.unavailable
        #endif
    }

    func managedJobsPending() throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedJobsPending(&error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func managedJobFile(messageID: String) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedJobFile(messageID, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func publishManagedJobReceipt(messageID: String, signatureBase64: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().publishManagedJobReceipt(messageID, signatureBase64: signatureBase64)
        #else
        throw Refusal.unavailable
        #endif
    }

    // Swift imports the binding's `…CheckIn…` selectors split at "In": `managedCheck(inPending:)`,
    // `managedCheck(inPayload:…)`, `publishManagedCheck(in:…)`. They are the transport's
    // ManagedCheckInPending, ManagedCheckInPayload and PublishManagedCheckIn.
    func managedCheckInPending() throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedCheck(inPending: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func managedCheckInPayload(challengeID: String, leaseRenewBy: Int64, appVersion: String,
                               appBuild: String) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedCheck(
            inPayload: challengeID, leaseRenewBy: leaseRenewBy, appVersion: appVersion, appBuild: appBuild, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func publishManagedCheckIn(challengeID: String, signatureBase64: String) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().publishManagedCheck(
            in: challengeID, signatureBase64: signatureBase64, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func managedRemovalReceiptPayload(removalID: String, actedAt: Int64) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedRemovalReceiptPayload(removalID, actedAt: actedAt, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func publishManagedRemovalReceipt(removalID: String, signatureBase64: String) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().publishManagedRemovalReceipt(
            removalID, signatureBase64: signatureBase64, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func publishManagedReport(payloadBase64: String, signatureBase64: String, recordBase64: String,
                              manifestBase64: String) throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().publishManagedReport(
            payloadBase64, signatureBase64: signatureBase64, recordBase64: recordBase64,
            manifestBase64: manifestBase64, error: &error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func publishManagedReportAttachment(sha256: String, path: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().publishManagedReportAttachment(sha256, path: path)
        #else
        throw Refusal.unavailable
        #endif
    }

    func managedReportReceipts() throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().managedReportReceipts(&error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func withdrawManagedReport(reportID: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().withdrawManagedReport(reportID)
        #else
        throw Refusal.unavailable
        #endif
    }

    func snapshot() throws -> String {
        #if AVENKIN_OFFICE_TRANSPORT
        var error: NSError?
        let value = try preparedClient().snapshot(&error)
        if let error { throw error }
        return value
        #else
        throw Refusal.unavailable
        #endif
    }

    func stop() {
        #if AVENKIN_OFFICE_TRANSPORT
        client?.stop()
        #endif
    }

    #if AVENKIN_OFFICE_TRANSPORT
    private func preparedClient() throws -> MobilecoreClient {
        if let client { return client }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let home = support.appendingPathComponent("AvenkinTransport", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var error: NSError?
        guard let prepared = MobilecoreNewClient(home.path, &error) else {
            throw error ?? Refusal.unavailable
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: home.appendingPathComponent("key.pem").path)
        let id = prepared.deviceID()
        guard !id.isEmpty else { throw Refusal.emptyIdentity }
        client = prepared
        return prepared
    }
    #endif
}
