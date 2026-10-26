import CoreBluetooth
import Foundation

/// Plan AH (Rokid) — the app's CoreBluetooth stack for Rokid Glasses, and the only
/// device-gated piece of the Rokid path. **Ships dark**: nothing reaches this class until
/// the user pairs the glasses in Settings and selects the Rokid backend.
///
/// The service and characteristic UUIDs below are **recovered, not guessed**: they are read
/// out of the glasses' own GATT server registration (`com.rokid.cxrservice`
/// `BLEServiceManager`, shipped in `CXRService.apk`) and confirmed against the device's live
/// GATT table. The stated properties come from that same registration.
///
/// **Status.** The `Caps` frame header is no longer open: it is the iAP2 link frame now
/// implemented in `RokidCapsCodec.swift`, recovered from a PacketLogger capture — see
/// `docs/rokid-caps-encoding.md`. Two things still gate this class. First, `connect()` has no
/// handshake. Second, and more fundamentally, the command channel is **MFi/iAP2 over Classic
/// Bluetooth, not GATT** (capture: ACL handle 12, CID `0x0051` out / `0x0b08` back), so the
/// UUIDs below are a discovery/notification bootstrap only. Real command traffic needs an
/// `EASession` transport over `com.rokid.aiglasses`, which `Info.plist` now declares.
///
/// Decisions (named per plan): **foreground-only v1** — no `bluetooth-central` background
/// mode, no state restoration; consistent with the app's other lifecycle constraints and
/// with `EvenBLETransport`. Rokid glasses are a single peripheral (one micro-display).
@MainActor
final class RokidBLETransport: NSObject, ObservableObject, RokidTransporting {

    /// `COMPOUND_SERVICE_UUID` — the single service the glasses expose for phone traffic.
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "00009100-0000-1000-8000-00805F9B34FB")
    /// `IOS_WRITE_CHAR_UUID` — property WRITE (0x08), permission WRITE. Phone → glasses.
    nonisolated(unsafe) static let writeCharUUID = CBUUID(string: "00009201-0000-1000-8000-00805F9B34FB")
    /// `IOS_NOTIFY_CHAR_UUID` — property NOTIFY (0x10), permission READ. Glasses → phone.
    nonisolated(unsafe) static let notifyCharUUID = CBUUID(string: "00009202-0000-1000-8000-00805F9B34FB")
    /// `IOS_CONNECTION_CHAR_UUID` — property READ; carries the connection record.
    nonisolated(unsafe) static let connectionCharUUID = CBUUID(string: "00009300-0000-1000-8000-00805F9B34FB")
    /// `RFCOMM_CONNECTION_CHAR_UUID` — property READ; carries the socket UUID iOS has no
    /// public API for, which is why the stream has to ride the notify/write pair instead.
    nonisolated(unsafe) static let rfcommConnectionCharUUID = CBUUID(string: "00009301-0000-1000-8000-00805F9B34FB")
    /// The glasses name their adapter `Glasses_<id>`; accept both spellings.
    nonisolated static let advertisedNamePrefixes = ["Rokid", "Glasses"]

    var onEvent: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Scanning (Settings pairing surface)

    /// Discovered-but-unpaired peripherals surfaced to the pairing UI.
    @Published private(set) var discovered: [(id: UUID, name: String)] = []
    private var scanning = false

    func startScan() {
        ensureCentral()
        scanning = true
        discovered = []
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: nil)
        }
    }

    func stopScan() {
        scanning = false
        central?.stopScan()
    }

    // MARK: - RokidTransporting

    var isConnected: Bool {
        peripheral?.state == .connected && writeCharacteristic != nil
    }

    func connect() async throws {
        guard Config.rokidPairingConfigured else { throw GlassesDisplayError.noDisplay }
        if isConnected { return }
        ensureCentral()
        guard let central, central.state == .poweredOn else {
            throw GlassesDisplayError.sessionUnavailable
        }

        guard let id = Config.rokidPeripheralID.flatMap(UUID.init(uuidString:)) else {
            throw GlassesDisplayError.sessionUnavailable
        }
        let retrieved = central.retrievePeripherals(withIdentifiers: [id])
        guard let peripheral = retrieved.first else { throw GlassesDisplayError.sessionUnavailable }
        self.peripheral = peripheral

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            peripheral.delegate = self
            central.connect(peripheral)
            // 10 s connect deadline — a dead device must not hang the render queue.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let pending = self.connectContinuation else { return }
                self.connectContinuation = nil
                pending.resume(throwing: GlassesDisplayError.sessionUnavailable)
            }
        }
        // NOTE: the device may expect an app-level handshake after connect (EVEN does).
        // Its bytes are not reliably documented — implement from a capture once hardware
        // is in hand. Until then rendering may be rejected; that surfaces through
        // `send`'s error path, honestly.
    }

    func disconnect() {
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        writeCharacteristic = nil
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected, let peripheral, let writeCharacteristic else {
            throw GlassesDisplayError.sessionUnavailable
        }
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: .withoutResponse)
    }

    // MARK: - Internals

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func resolveConnectIfReady() {
        guard connectContinuation != nil, isConnected else { return }
        connectContinuation?.resume(returning: ())
        connectContinuation = nil
    }
}

extension RokidBLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn, self.scanning {
                central.scanForPeripherals(withServices: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard Self.advertisedNamePrefixes.contains(where: { name.hasPrefix($0) }) else { return }
        let id = peripheral.identifier
        Task { @MainActor in
            if !self.discovered.contains(where: { $0.id == id }) {
                self.discovered.append((id: id, name: name))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.writeCharacteristic = nil
            if !self.isConnected {
                self.onDisconnect?(error)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.writeCharUUID:
                    self.writeCharacteristic = characteristic
                case Self.notifyCharUUID:
                    peripheral.setNotifyValue(true, for: characteristic)
                default:
                    break
                }
            }
            self.resolveConnectIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyCharUUID, let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        Task { @MainActor in
            self.onEvent?(bytes)
        }
    }
}
