import Foundation

/// Which ring is paired and how far it has synced (Plan MZ P2). No readings: a pairing id made
/// when the ring was paired, the CoreBluetooth identifier this phone knows it by, the sync cursors
/// (dates only), the clock the ring was last set to, and when it last synced.
///
/// Registered with `DataStoreRegistry` as `ringPairing`.
struct RingPairingRecord: Codable, Equatable, Sendable {
    /// Names the ring in sync identifiers; never its address or the CoreBluetooth identifier.
    var pairingID: RingPairingID
    /// How this phone's Bluetooth names the ring. Never logged or sent anywhere.
    var peripheralIdentifier: UUID
    var cursor: RingSyncCursor
    /// The offset the ring's clock was last set with (`RingClock`), so a night recorded before a
    /// time zone change is still read at the right hours.
    var latchedClock: RingClock?
    var pairedAt: Date
    var lastSync: Date?

    init(pairingID: RingPairingID, peripheralIdentifier: UUID, cursor: RingSyncCursor = RingSyncCursor(),
         latchedClock: RingClock? = nil, pairedAt: Date, lastSync: Date? = nil) {
        self.pairingID = pairingID
        self.peripheralIdentifier = peripheralIdentifier
        self.cursor = cursor
        self.latchedClock = latchedClock
        self.pairedAt = pairedAt
        self.lastSync = lastSync
    }
}

/// Where the pairing record lives. The live one is `RingPairingStore`; tests use a suite of their
/// own or a fake.
@MainActor
protocol RingPairingStoring: AnyObject {
    func load() -> RingPairingRecord?
    func save(_ record: RingPairingRecord)
    func clear()
}

/// The pairing record in preferences, as one JSON value. Forgetting the ring clears it.
@MainActor
final class RingPairingStore: RingPairingStoring {

    nonisolated static let key = "ringPairingRecord"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RingPairingRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RingPairingRecord.self, from: data)
    }

    func save(_ record: RingPairingRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Forget the ring: the pairing id, the identifier, the cursors and the latched clock go.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// The ring's settings. Small scalars only; the pairing record has its own store.
extension Config {
    /// Plan MZ: the smart ring, off until the device pass. Developer panel only; off shows nothing
    /// ring-related anywhere and never starts Bluetooth for it.
    static var ringSupportEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ringSupportEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "ringSupportEnabled") }
    }

    /// The pairing record, read and written through `RingPairingStore`.
    @MainActor
    static var ringPairing: RingPairingRecord? {
        get { RingPairingStore().load() }
        set {
            if let newValue { RingPairingStore().save(newValue) } else { RingPairingStore().clear() }
        }
    }

    /// The ring's automatic heart rate: 0 is off, otherwise minutes. Decision 4: every 30 minutes.
    static var ringHeartRateMinutes: Int {
        get { UserDefaults.standard.object(forKey: "ringHeartRateMinutes") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "ringHeartRateMinutes") }
    }

    static var ringHeartRateSchedule: RingHeartRateSchedule {
        RingHeartRateSetting(minutes: ringHeartRateMinutes).schedule
    }

    /// The clench trigger. On by default once a ring is paired (Plan MZ decision 8).
    static var ringTriggerEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ringTriggerEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ringTriggerEnabled") }
    }

    /// What a clench does, as `TempleAction.rawValue`. Decision 8: start talking.
    static var ringTriggerActionRaw: String {
        get { UserDefaults.standard.string(forKey: "ringTriggerAction") ?? TempleAction.startTalking.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "ringTriggerAction") }
    }

    static var ringTriggerSetting: RingTriggerSetting {
        RingTriggerSetting(enabled: ringTriggerEnabled, action: TempleAction(rawValue: ringTriggerActionRaw))
    }

    /// The note that the ring's own app still holds it (decision 9) was shown. Cleared by Forget.
    static var ringOtherAppNoticeShown: Bool {
        get { UserDefaults.standard.bool(forKey: "ringOtherAppNoticeShown") }
        set { UserDefaults.standard.set(newValue, forKey: "ringOtherAppNoticeShown") }
    }
}

/// The automatic heart-rate choices the settings offer. Only these cadences have been seen working.
enum RingHeartRateSetting: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case every30Minutes = 30
    case every10Minutes = 10

    var id: Int { rawValue }

    /// Anything else stored reads as the recommended 30 minutes.
    init(minutes: Int) {
        self = RingHeartRateSetting(rawValue: minutes) ?? .every30Minutes
    }

    var schedule: RingHeartRateSchedule {
        self == .off ? .off : .every(minutes: rawValue)
    }

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .every30Minutes: return String(localized: "Every 30 minutes")
        case .every10Minutes: return String(localized: "Every 10 minutes")
        }
    }
}
