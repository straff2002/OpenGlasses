import Foundation

/// Device-only record of the owner's reviewed office identities and the exact signed envelope.
/// This is input to fresh verification, never authority on its own. A generation high-water is
/// stored separately so deleting or replacing this record cannot make an older binding valid.
actor OfficeApprovedPeerStore {
    struct Stored: Codable, Sendable {
        let version: Int
        let scopeID: String
        let officeID: String
        let officeTransportID: String
        let officeApplicationKey: Data
        let signedBinding: Data
    }

    enum Refusal: Error, Equatable {
        case corruptState
    }

    static let shared = OfficeApprovedPeerStore()
    private let keyPrefix: String

    init(keyPrefix: String = "office.peer.approved.v1.") {
        self.keyPrefix = keyPrefix
    }

    func save(_ signedBinding: Data, organizationID: String, enrolmentID: String,
              officeID: String, officeTransportID: String, officeApplicationKey: Data) throws {
        let scope = try OfficePeerHighWaterStore.scopeID(
            organizationID: organizationID, enrolmentID: enrolmentID)
        guard signedBinding.count <= OfficePeerBinding.maximumEnvelopeBytes,
              !signedBinding.isEmpty, officeApplicationKey.count == 32,
              OfficeManualAssignment.safeIdentifier(officeID),
              !officeTransportID.isEmpty, officeTransportID.utf8.count <= 128 else {
            throw Refusal.corruptState
        }
        let record = Stored(version: 1, scopeID: scope, officeID: officeID,
                            officeTransportID: officeTransportID,
                            officeApplicationKey: officeApplicationKey, signedBinding: signedBinding)
        let data = try JSONEncoder().encode(record)
        guard data.count <= 48_000 else { throw Refusal.corruptState }
        try KeychainService.upsertDataAtomically(data, for: keyPrefix + scope,
                                                  accessibility: .afterFirstUnlockThisDeviceOnly)
    }

    func read(organizationID: String, enrolmentID: String) throws -> Stored? {
        let scope = try OfficePeerHighWaterStore.scopeID(
            organizationID: organizationID, enrolmentID: enrolmentID)
        guard let data = try KeychainService.readData(for: keyPrefix + scope) else { return nil }
        guard data.count <= 48_000,
              let record = try? JSONDecoder().decode(Stored.self, from: data),
              record.version == 1, record.scopeID == scope,
              OfficeManualAssignment.safeIdentifier(record.officeID),
              !record.officeTransportID.isEmpty, record.officeTransportID.utf8.count <= 128,
              record.officeApplicationKey.count == 32,
              !record.signedBinding.isEmpty,
              record.signedBinding.count <= OfficePeerBinding.maximumEnvelopeBytes else {
            throw Refusal.corruptState
        }
        return record
    }
}
