import Foundation

/// Protected storage for FHIR secrets, addressed one server at a time. There is deliberately no
/// "read all credentials" call: a caller can only ask for the server it is about to talk to.
protocol FHIRCredentialStore {
    func load(serverID: String) throws -> FHIRCredential?
    func save(_ credential: FHIRCredential, serverID: String) throws
    func delete(serverID: String) throws
}

/// Protected storage for clinical identifiers. A separate protocol (and, in the Keychain
/// implementation, a separate item namespace) from the credential store, so neither a query nor a
/// future `Codable` change can recombine secrets with regulated medical data.
protocol FHIRPrivateContextStore {
    func loadContext(serverID: String) throws -> FHIRPrivateContext?
    func saveContext(_ context: FHIRPrivateContext, serverID: String) throws
    func deleteContext(serverID: String) throws
}

/// Keychain-backed store for both kinds of protected FHIR value.
///
/// Items use the when-unlocked, this-device-only class: an export is a foreground action, so
/// nothing here needs to survive a locked screen, and a stricter class is one fewer way for a
/// clinical secret to be read off a device that is not in the user's hands.
struct KeychainFHIRSecretStore: FHIRCredentialStore, FHIRPrivateContextStore {
    private static let credentialPrefix = "fhir.credential."
    private static let contextPrefix = "fhir.privateContext."
    private static let accessibility = KeychainService.Accessibility.whenUnlockedThisDeviceOnly

    func load(serverID: String) throws -> FHIRCredential? {
        try read(FHIRCredential.self, account: Self.credentialPrefix + serverID)
    }

    func save(_ credential: FHIRCredential, serverID: String) throws {
        try write(credential, isEmpty: credential.isEmpty, account: Self.credentialPrefix + serverID)
    }

    func delete(serverID: String) throws {
        try KeychainService.deleteItem(Self.credentialPrefix + serverID)
    }

    func loadContext(serverID: String) throws -> FHIRPrivateContext? {
        try read(FHIRPrivateContext.self, account: Self.contextPrefix + serverID)
    }

    func saveContext(_ context: FHIRPrivateContext, serverID: String) throws {
        try write(context, isEmpty: context.isEmpty, account: Self.contextPrefix + serverID)
    }

    func deleteContext(serverID: String) throws {
        try KeychainService.deleteItem(Self.contextPrefix + serverID)
    }

    // MARK: - Item plumbing

    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try KeychainService.readData(for: account) else { return nil }
        // A corrupt item is not a recoverable secret. Report it as absent rather than throwing —
        // the caller's "no credential stored" path is the honest outcome and stays actionable.
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, isEmpty: Bool, account: String) throws {
        guard !isEmpty else {
            try KeychainService.deleteItem(account)
            return
        }
        let data = try JSONEncoder().encode(value)
        try KeychainService.writeData(data, for: account, accessibility: Self.accessibility)
    }
}
