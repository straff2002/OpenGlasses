import Foundation

/// The Bluetooth half of the ring, as a seam (Plan MZ §7). `RingBLETransport` is the live one
/// (CoreBluetooth, glasses build only); tests use a fake that plays the ring.
///
/// The transport finds rings, holds one link, writes what it is given and reports what arrives.
/// It decides nothing: `RingService` drives the sync machine and chooses when to connect.
@MainActor
protocol RingTransporting: AnyObject {
    /// Everything the transport has to say, in the order it happened.
    var onEvent: ((RingTransportEvent) -> Void)? { get set }

    /// Look for rings: advertising ones, and ones another app on this phone already holds.
    func startScan()
    func stopScan()
    /// Connect to a ring found by a scan or paired earlier. The connect stays pending until the
    /// ring is in range; `disconnect()` withdraws it.
    func connect(to peripheral: UUID)
    func disconnect()
    /// Write one packet to the protocol's write characteristic.
    func write(_ bytes: [UInt8])
    /// Read the standard battery level; answered with `.battery`.
    func readBattery()
}

/// What the transport reports.
enum RingTransportEvent: Equatable, Sendable {
    /// The phone's Bluetooth changed state.
    case radio(RingRadioState)
    /// A ring the driver recognises.
    case discovered(RingCandidate)
    /// Connected, the protocol service found and its notifications subscribed. Nothing is
    /// forwarded before this.
    case ready
    /// One notification from the ring.
    case notification([UInt8])
    /// The standard battery level, or nil when the read failed.
    case battery(Int?)
    /// The link dropped, or a pending connect failed.
    case disconnected
}

/// The phone's Bluetooth, in the app's own words.
enum RingRadioState: String, Equatable, Sendable {
    case unknown
    case poweredOn
    case poweredOff
    /// The wearer has not allowed the app to use Bluetooth.
    case unauthorized
    case unsupported
}

/// A ring a scan found. Its CoreBluetooth identifier is how this phone names that ring; it is kept
/// as the paired ring but never logged, never sent anywhere and never used as a sync identifier.
/// The address some rings put in their advertisements is never read into it.
struct RingCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    /// What the ring is called on screen. Never the vendor's name.
    let displayName: String
    /// Found through the connections another app on this phone already holds (the ring's own
    /// app): that app may still change the ring's clock and schedule (Plan MZ decision 9).
    let heldByAnotherApp: Bool
}

/// How a scan result becomes a candidate, kept apart from CoreBluetooth so it can be tested.
enum RingScanMatch {

    /// What the ring is called in the app, whatever it advertises.
    static let displayName = String(localized: "Smart ring")

    /// A candidate for an advertisement the driver recognises, by advertised name or by the
    /// company identifier at the start of the manufacturer data; nil for anything else. There is
    /// deliberately no address parameter: a ring is never matched by the address it broadcasts.
    static func candidate(id: UUID, advertisement: RingAdvertisement, driver: RingDriver) -> RingCandidate? {
        guard driver.recognises(advertisement) else { return nil }
        return RingCandidate(id: id, displayName: displayName, heldByAnotherApp: false)
    }

    /// A ring another app already holds: it does not advertise, so it is recognised by the
    /// protocol service it was retrieved with.
    static func connectedCandidate(id: UUID) -> RingCandidate {
        RingCandidate(id: id, displayName: displayName, heldByAnotherApp: true)
    }

    /// An advertisement from CoreBluetooth's dictionary, read by its documented key strings so the
    /// pure half never imports CoreBluetooth. The manufacturer data is copied as is; recognition
    /// reads only its first two bytes, the company identifier.
    static func advertisement(from data: [String: Any], peripheralName: String?) -> RingAdvertisement {
        let localName = (data[localNameKey] as? String) ?? peripheralName
        let manufacturer = (data[manufacturerDataKey] as? Data).map { [UInt8]($0) }
        let services = (data[serviceUUIDsKey] as? [Any])?.map { String(describing: $0) } ?? []
        return RingAdvertisement(localName: localName, serviceUUIDs: services, manufacturerData: manufacturer)
    }

    /// `CBAdvertisementDataLocalNameKey`, `CBAdvertisementDataManufacturerDataKey` and
    /// `CBAdvertisementDataServiceUUIDsKey`, as CoreBluetooth defines them.
    static let localNameKey = "kCBAdvDataLocalName"
    static let manufacturerDataKey = "kCBAdvDataManufacturerData"
    static let serviceUUIDsKey = "kCBAdvDataServiceUUIDs"
}
