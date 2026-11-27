import Foundation

/// The clinic workbook connection as this phone keeps it (Plan NK §3): the sign-in's tokens, the
/// client id it used, the account's name, the workbook chosen and its name, the organisation's
/// country, and when rows last reached it. One device-only Keychain item, so none of it reaches a
/// backup, a profile or us. Its descriptions never show a token.
struct ClinicWorkbookConnectionRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {
    var clientID: String
    var credentials: EntraOAuth.Credentials
    var account: String?
    var workbook: GraphWorkbook?
    var workbookName: String?
    var country: String?
    var lastSentAt: Date?

    var description: String {
        "ClinicWorkbookConnectionRecord(workbook: \(workbook == nil ? "none" : "chosen"), tokens redacted)"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["workbook": workbook == nil ? "none" : "chosen", "tokens": "redacted"], displayStyle: .struct)
    }
}

/// The connection's three Keychain items (Plan NK P1), all `afterFirstUnlockThisDeviceOnly`:
/// - `clinicStockWorkbook.connection`: the record above; removed on Sign out;
/// - `clinicStockWorkbook.ledger`: what this phone has sent to each workbook, by row key
///   (`ClinicalStockSendLedger`). Kept on Sign out, so signing in again to the same workbook never
///   adds a row twice;
/// - `clinicStockWorkbook.seat`: a random id made on this phone, the seat its row keys are made
///   from. It identifies nothing outside the clinic's workbook and is never sent as it is.
///
/// Registered with `DataStoreRegistry` as `clinicStockWorkbook`; `removeAll()` erases all three.
@MainActor
final class ClinicWorkbookConnectionStore {

    nonisolated static let connectionAccount = "clinicStockWorkbook.connection"
    nonisolated static let ledgerAccount = "clinicStockWorkbook.ledger"
    nonisolated static let seatAccount = "clinicStockWorkbook.seat"
    /// The clinic's own client id, entered on this phone: a public identifier, not a secret.
    nonisolated static let clinicClientIDKey = "clinicStockWorkbookClientID"

    struct Storage {
        var read: (String) throws -> Data? = { try KeychainService.readData(for: $0) }
        var write: (Data, String) throws -> Void = {
            try KeychainService.upsertDataAtomically($0, for: $1, accessibility: .afterFirstUnlockThisDeviceOnly)
        }
        var erase: (String) throws -> Void = { try KeychainService.deleteItem($0) }
        var makeSeat: () -> String = { UUID().uuidString }
    }

    private let storage: Storage
    private(set) var record: ClinicWorkbookConnectionRecord?

    init(storage: Storage = Storage()) {
        self.storage = storage
        record = (try? storage.read(Self.connectionAccount)).flatMap { $0 }
            .flatMap { try? Self.decoder.decode(ClinicWorkbookConnectionRecord.self, from: $0) }
    }

    /// Every token stored here, for the diagnostics redactor only (`Config.knownSecretValues`).
    /// Never format, log or send the result.
    nonisolated static func knownTokens() -> [String] {
        guard let data = KeychainService.data(for: connectionAccount),
              let record = try? decoder.decode(ClinicWorkbookConnectionRecord.self, from: data) else { return [] }
        return [record.credentials.accessToken, record.credentials.refreshToken].compactMap { $0 }
    }

    @discardableResult
    func save(_ record: ClinicWorkbookConnectionRecord) -> Bool {
        guard let data = try? Self.encoder.encode(record), (try? storage.write(data, Self.connectionAccount)) != nil else {
            return false
        }
        self.record = record
        return true
    }

    /// Sign out: the tokens and the choice go. The ledger and the seat stay.
    func signOut() {
        try? storage.erase(Self.connectionAccount)
        record = nil
    }

    /// Everything: the connection, the ledgers and the seat.
    func removeAll() {
        for account in [Self.connectionAccount, Self.ledgerAccount, Self.seatAccount] { try? storage.erase(account) }
        record = nil
    }

    // MARK: - The seat

    /// This phone's seat, made the first time it is asked for.
    func seat() -> String {
        if let data = (try? storage.read(Self.seatAccount)).flatMap({ $0 }), let seat = String(data: data, encoding: .utf8),
           !seat.isEmpty {
            return seat
        }
        let seat = storage.makeSeat()
        try? storage.write(Data(seat.utf8), Self.seatAccount)
        return seat
    }

    // MARK: - The ledger

    private func ledgers() -> [String: ClinicalStockSendLedger] {
        (try? storage.read(Self.ledgerAccount)).flatMap { $0 }
            .flatMap { try? Self.decoder.decode([String: ClinicalStockSendLedger].self, from: $0) } ?? [:]
    }

    nonisolated static func ledgerKey(_ workbook: GraphWorkbook) -> String {
        workbook.driveID + "/" + workbook.itemID
    }

    func ledger(for workbook: GraphWorkbook) -> ClinicalStockSendLedger {
        ledgers()[Self.ledgerKey(workbook)] ?? ClinicalStockSendLedger()
    }

    @discardableResult
    func saveLedger(_ ledger: ClinicalStockSendLedger, for workbook: GraphWorkbook) -> Bool {
        var all = ledgers()
        all[Self.ledgerKey(workbook)] = ledger
        guard let data = try? Self.encoder.encode(all) else { return false }
        return (try? storage.write(data, Self.ledgerAccount)) != nil
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
