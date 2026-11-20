import Foundation
import Combine

/// Which of a system's accounts a connection talks to (Plan MM P2): the business's own, or a
/// sandbox for testing, when the adapter has a sandbox host.
enum StockSystemEnvironment: String, Codable, CaseIterable, Sendable {
    case production
    case sandbox
}

/// One connection to a business's own stock system, as it is kept on this phone (Plan MM §3): the
/// key and every choice made in Settings › Field Assist › Stock system, in one device-only Keychain
/// item per connector, so the key and the choices are written, read and erased together.
///
/// Never in a profile, a backup, a log or a description: its descriptions say which connector and
/// how many locations, never the key. Registered with `DataStoreRegistry` as
/// `stockSystemConnection`.
struct StockSystemConnectionRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable {

    /// The most locations one connection holds.
    static let locationCap = 50

    let connectorID: String
    var key: String
    /// Changes with every new key, so a reply to a request made with the old one is not trusted.
    var generation: String
    var environment: StockSystemEnvironment
    /// The system's locations that are this place ("Which stock is here?"), with their names.
    var locations: [StockSystemLocation]
    /// Whether parts used are sent back once a person confirms them. Off until someone turns it on.
    var sendingBack: Bool
    /// The adjustment reason for parts used and not sold.
    var reason: StockAdjustmentReason?
    /// Who the technician is in a system with jobs ("Who are you there?"). Not used by a system
    /// without jobs.
    var externalUserID: String?
    /// The account as the person sees it, when the system names one.
    var accountLabel: String?

    init(connectorID: String, key: String, environment: StockSystemEnvironment, generation: String = UUID().uuidString) {
        self.connectorID = connectorID
        self.key = key
        self.generation = generation
        self.environment = environment
        self.locations = []
        self.sendingBack = false
        self.reason = nil
        self.externalUserID = nil
        self.accountLabel = nil
    }

    var locationIDs: [String] { locations.map(\.id) }

    var description: String {
        "StockSystemConnectionRecord(\(connectorID), \(environment.rawValue), \(locations.count) location(s), key redacted)"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(self, children: [
            "connectorID": connectorID, "environment": environment.rawValue, "locations": locations.count,
            "sendingBack": sendingBack, "key": "redacted",
        ], displayStyle: .struct)
    }
}

/// Why a change to a connection was refused.
enum StockSystemConnectionError: Error, Equatable, Sendable {
    /// The office connects outside systems, the phone is managed and no administrator is here,
    /// Field Assist is not licensed, or the connection is switched off.
    case notAllowed
    /// The pasted key is not one the phone will send.
    case badKey
    /// The system has no sandbox.
    case noSandbox
    /// There is no connection to change.
    case noConnection
    /// The organisation's profile has locked this choice.
    case locked
}

/// The stock system connections on this phone (Plan MM P2), mirroring the Workiz connection: the key
/// in a device-only Keychain item, the office route ceiling checked the same way, the key pasted
/// behind the administrator's passcode on a managed phone, and everything erased on Remove, when the
/// phone leaves its organisation, and when the office route arrives. Vendor-neutral: connector ids
/// come from `StockSystemAdapterRegistry`.
@MainActor
final class StockSystemConnectionStore: ObservableObject {

    /// One Keychain item per connector: `stockSystemConnection.<connector>`.
    nonisolated static let keychainAccountPrefix = "stockSystemConnection."
    /// The system chosen in Settings (the profile may set and lock it).
    nonisolated static let selectedConnectorKey = "stockSystemConnector"
    /// Connectors whose Keychain item could not be erased yet: never read again, erased on the
    /// next chance.
    nonisolated static let pendingEraseKey = "stockSystemPendingErase"

    nonisolated static func keychainAccount(_ connectorID: String) -> String {
        keychainAccountPrefix + connectorID
    }

    /// Every stored key on this phone, for the diagnostics redactor only (`Config.knownSecretValues`).
    /// Never format, log or send the result.
    nonisolated static func knownKeys(connectorIDs: [String] = StockSystemAdapterRegistry.connectorIDs) -> [String] {
        connectorIDs.compactMap { id in
            KeychainService.data(for: keychainAccount(id))
                .flatMap { try? JSONDecoder().decode(StockSystemConnectionRecord.self, from: $0) }?.key
        }
    }

    struct Storage {
        var read: (String) throws -> Data? = { try KeychainService.readData(for: $0) }
        var write: (Data, String) throws -> Void = {
            try KeychainService.upsertDataAtomically($0, for: $1, accessibility: .afterFirstUnlockThisDeviceOnly)
        }
        var erase: (String) throws -> Void = { try KeychainService.deleteItem($0) }
        var selected: () -> String? = { UserDefaults.standard.string(forKey: StockSystemConnectionStore.selectedConnectorKey) }
        var setSelected: (String?) -> Void = { UserDefaults.standard.set($0, forKey: StockSystemConnectionStore.selectedConnectorKey) }
        var pendingErase: () -> [String] = { UserDefaults.standard.stringArray(forKey: StockSystemConnectionStore.pendingEraseKey) ?? [] }
        var setPendingErase: ([String]) -> Void = {
            if $0.isEmpty { UserDefaults.standard.removeObject(forKey: StockSystemConnectionStore.pendingEraseKey) }
            else { UserDefaults.standard.set($0, forKey: StockSystemConnectionStore.pendingEraseKey) }
        }
    }

    private let storage: Storage
    private let licensed: () -> Bool
    let connectorIDs: [String]
    @Published private(set) var records: [String: StockSystemConnectionRecord] = [:]
    @Published private(set) var problem: String?
    @Published private(set) var revision = 0

    init(storage: Storage = Storage(), connectorIDs: [String] = StockSystemAdapterRegistry.connectorIDs,
         licensed: @escaping () -> Bool = { Config.fieldAssistUnlocked }) {
        self.storage = storage
        self.connectorIDs = connectorIDs
        self.licensed = licensed
        let pending = Set(storage.pendingErase())
        var stillPending: [String] = []
        for id in connectorIDs {
            if pending.contains(id) {
                do { try storage.erase(Self.keychainAccount(id)) } catch { stillPending.append(id) }
                continue
            }
            do {
                if let data = try storage.read(Self.keychainAccount(id)),
                   let record = try? JSONDecoder().decode(StockSystemConnectionRecord.self, from: data), record.connectorID == id {
                    records[id] = record
                }
            } catch {
                problem = String(localized: "Unlock this phone to read the stock system connection.")
            }
        }
        if stillPending.count != pending.count { storage.setPendingErase(stillPending) }
    }

    // MARK: - What is in force

    /// The office connects outside systems (verified the same way as Workiz's ceiling).
    var officeRoute: Bool { PolicyEnvelope.string(.organizationFieldServiceRoute, stored: "") == "office" }
    /// A profile may switch the connection off; otherwise it is on wherever one is set up.
    var enabled: Bool { PolicyEnvelope.bool(.stockSystemEnabled, stored: true) }
    var isLicensed: Bool { licensed() }

    /// The system chosen: the profile's, else this phone's choice, else the first on offer.
    var selectedConnectorID: String {
        let chosen = PolicyEnvelope.string(.stockSystemConnector, stored: storage.selected() ?? "")
        return connectorIDs.contains(chosen) ? chosen : (connectorIDs.first ?? "")
    }

    var record: StockSystemConnectionRecord? { records[selectedConnectorID] }

    /// A connection that may talk to its system: there is one, it is on, the office does not
    /// connect the system for this firm, and Field Assist is licensed.
    var isRunning: Bool { record != nil && enabled && !officeRoute && licensed() }

    /// Whether parts used go back (the profile's, else the connection's; off by default).
    var sendingBack: Bool { PolicyEnvelope.bool(.stockSystemSendBack, stored: record?.sendingBack ?? false) }

    /// The adjustment reason in force (the profile's, else the connection's).
    var reason: StockAdjustmentReason? {
        StockAdjustmentReason(rawValue: PolicyEnvelope.string(.stockSystemAdjustmentReason, stored: record?.reason?.rawValue ?? ""))
    }

    /// The organisation's profile has locked the reason.
    var reasonLocked: Bool { PolicyEnvelope.isLocked(.stockSystemAdjustmentReason) }

    /// The reason parts used are sent with, for a system that keeps `kept`
    /// (`StockAdjustmentReason.effective`): the one in force when the system keeps it, else the
    /// system's only reason, else none. A locked reason is never replaced.
    func effectiveReason(kept: Set<StockAdjustmentReason>) -> StockAdjustmentReason? {
        StockAdjustmentReason.effective(chosen: reason, kept: kept, locked: reasonLocked)
    }

    /// The connection as deciding who answers needs it (`StockAuthority.resolve`).
    var authorityConnection: StockSystemConnection? {
        guard isRunning, let record else { return nil }
        return StockSystemConnection(connectorID: record.connectorID, locationIDs: record.locationIDs)
    }

    /// The last four characters of the key, for an administrator only. Never the key.
    var keyEnding: String? { record.flatMap { StockSystemCredential($0.key)?.ending } }

    // MARK: - Changing

    /// Choose the system. Refused while the profile has locked the choice.
    func select(_ connectorID: String) throws {
        guard !PolicyEnvelope.isLocked(.stockSystemConnector) else { throw StockSystemConnectionError.locked }
        guard connectorIDs.contains(connectorID) else { throw StockSystemConnectionError.notAllowed }
        storage.setSelected(connectorID)
        revision += 1
    }

    /// Save a pasted key for the chosen system. The save path checks the administrator session on a
    /// managed phone: disabling a field alone is not a gate. A new key for the same environment
    /// keeps the choices; another environment is another account, so they start again.
    func pasteKey(_ raw: String, environment: StockSystemEnvironment, administrator: Bool,
                  hasSandbox: Bool) throws {
        guard !officeRoute, enabled, licensed(), !PolicyEnvelope.isManaged || administrator else {
            throw StockSystemConnectionError.notAllowed
        }
        guard environment == .production || hasSandbox else { throw StockSystemConnectionError.noSandbox }
        guard let credential = StockSystemCredential(raw) else { throw StockSystemConnectionError.badKey }
        let id = selectedConnectorID
        guard !id.isEmpty else { throw StockSystemConnectionError.notAllowed }
        var next = StockSystemConnectionRecord(connectorID: id, key: credential.key, environment: environment)
        if let current = records[id], current.environment == environment {
            next.locations = current.locations
            next.sendingBack = current.sendingBack
            next.reason = current.reason
            next.externalUserID = current.externalUserID
            next.accountLabel = current.accountLabel
        }
        try commit(next)
    }

    /// "Which stock is here?": the system's locations that are this place, each once, at most
    /// `locationCap`.
    func chooseLocations(_ locations: [StockSystemLocation]) throws {
        guard var next = record else { throw StockSystemConnectionError.noConnection }
        var seen = Set<String>()
        next.locations = Array(locations.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .prefix(StockSystemConnectionRecord.locationCap))
        try commit(next)
    }

    /// Sending back on or off. Refused while the profile has locked it. Turned on with no reason
    /// stored that the system keeps (`kept`), the reason Settings shows is stored with it, so what
    /// the screen says and what is sent agree; a locked reason is left as the profile set it.
    func setSendingBack(_ on: Bool, kept: Set<StockAdjustmentReason> = []) throws {
        guard !PolicyEnvelope.isLocked(.stockSystemSendBack) else { throw StockSystemConnectionError.locked }
        guard var next = record else { throw StockSystemConnectionError.noConnection }
        next.sendingBack = on
        if on, !reasonLocked, !kept.isEmpty, next.reason.map(kept.contains) != true {
            next.reason = effectiveReason(kept: kept) ?? StockAdjustmentReason.ordered(kept).first
        }
        try commit(next)
    }

    /// The adjustment reason. Refused while the profile has locked it.
    func setReason(_ reason: StockAdjustmentReason?) throws {
        guard !PolicyEnvelope.isLocked(.stockSystemAdjustmentReason) else { throw StockSystemConnectionError.locked }
        guard var next = record else { throw StockSystemConnectionError.noConnection }
        next.reason = reason
        try commit(next)
    }

    private func commit(_ next: StockSystemConnectionRecord) throws {
        try storage.write(JSONEncoder().encode(next), Self.keychainAccount(next.connectorID))
        storage.setPendingErase(storage.pendingErase().filter { $0 != next.connectorID })
        records[next.connectorID] = next
        problem = nil
        revision += 1
    }

    /// Erase one connector's key and choices. The connection stops at once; an erase the locked
    /// phone refuses is kept pending and retried at the next launch, and the item is never read
    /// again meanwhile.
    func remove(_ connectorID: String) throws {
        storage.setPendingErase(Array(Set(storage.pendingErase() + [connectorID])).sorted())
        records[connectorID] = nil
        revision += 1
        do {
            try storage.erase(Self.keychainAccount(connectorID))
            storage.setPendingErase(storage.pendingErase().filter { $0 != connectorID })
            problem = nil
        } catch {
            problem = String(localized: "The stock system is stopped. Unlock this phone to finish removing its key.")
            throw error
        }
    }

    /// Erase every connector's key and choices: Remove for all, leaving the organisation, the office
    /// route arriving.
    func removeAll() throws {
        var failure: Error?
        for id in connectorIDs {
            do { try remove(id) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}
