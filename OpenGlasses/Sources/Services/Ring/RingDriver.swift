import Foundation

/// The device-agnostic seam for a family of rings (Plan MZ §2).
///
/// A driver says how its rings are recognised, which GATT characteristics carry its protocol, what
/// the rings can do, and how the app's commands and the ring's packets map onto each other. Only
/// `SmartRingDriver` exists; another family is a new driver and its tests, nothing above changes.
protocol RingDriver: Sendable {
    /// Names the rings advertise under.
    var advertisedNames: Set<String> { get }
    /// The service UUID the rings advertise, for the scan filter.
    var advertisedService: String { get }
    /// The Bluetooth company identifier at the start of the rings' manufacturer data, if any.
    var manufacturerID: UInt16? { get }
    /// Where the protocol lives once connected.
    var gatt: RingGATTRoles { get }
    /// What these rings can do.
    var capabilities: Set<RingCapability> { get }

    /// The bytes to write for a command.
    func encode(_ command: RingCommand) -> [UInt8]
    /// What a notification says. A packet it cannot read yields `.unknown` or `.malformed`.
    func decode(_ packet: [UInt8]) -> [RingEvent]
}

extension RingDriver {
    /// Whether an advertisement is one of this family's rings: by advertised name or by the
    /// company identifier that begins its manufacturer data. Never by address — the bytes after
    /// the company identifier (which on some rings are the ring's own address) are not read.
    func recognises(_ advertisement: RingAdvertisement) -> Bool {
        if let name = advertisement.localName, advertisedNames.contains(name) { return true }
        if let manufacturerID, let companyID = advertisement.companyID, companyID == manufacturerID {
            return true
        }
        return false
    }
}

/// What a scan saw, reduced to what recognition needs. Built by the Bluetooth transport.
struct RingAdvertisement: Equatable, Sendable {
    let localName: String?
    /// Advertised service UUIDs in CoreBluetooth's string form.
    let serviceUUIDs: [String]
    /// Manufacturer data as CoreBluetooth reports it: the company identifier (little-endian) first.
    let manufacturerData: [UInt8]?

    /// The company identifier, when the manufacturer data is long enough to hold one.
    var companyID: UInt16? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        return UInt16(data[0]) | UInt16(data[1]) << 8
    }
}

/// Where a ring's protocol lives, as UUID strings CoreBluetooth accepts (`CBUUID(string:)`).
struct RingGATTRoles: Equatable, Sendable {
    /// The service carrying the protocol.
    let service: String
    /// The characteristic commands are written to.
    let write: String
    /// Whether writes need a response (the characteristic's property is *write*, not
    /// *write without response*). The sync machine serialises writes either way.
    let writeWithResponse: Bool
    /// The characteristic notifications arrive on.
    let notify: String
    /// The standard Battery Service and its level characteristic, if the ring has them.
    let batteryService: String?
    let batteryLevel: String?
}
