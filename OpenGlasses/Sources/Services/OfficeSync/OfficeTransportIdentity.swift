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

    /// Handshake-only: the embedded engine pins the office certificate and creates no folder.
    /// The caller must reverify the saved organisation approval before invoking this method.
    func startManagedOffice(transportID: String, lanAddress: String) throws {
        #if AVENKIN_OFFICE_TRANSPORT
        try preparedClient().startManagedOffice(transportID, address: lanAddress)
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
