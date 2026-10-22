import CoreBluetooth
import Foundation

/// Plan AH (Rokid) — the app's CoreBluetooth stack for Rokid Glasses, and the only
/// device-gated piece of the Rokid path. **Ships dark**: nothing reaches this class until
/// the user pairs the glasses in Settings and selects the Rokid backend, and the wire
/// assumptions below (characteristic UUIDs, Caps framing, any app-level handshake) are a
/// community reconstruction awaiting hardware validation.
///
/// Decisions (named per plan): **foreground-only v1** — no `bluetooth-central` background
/// mode, no state restoration; consistent with the app's other lifecycle constraints and
/// with `EvenBLETransport`. Rokid glasses are a single peripheral (one micro-display).
///
/// The community docs name the characteristics (`IOS_WRITE_CHAR`, `IOS_NOTIFY_CHAR`, …)
/// but not their UUIDs, so the constants here are placeholders resolved by the Phase 1
/// capture pass — same honesty stance as the EVEN reconstruction.
@MainActor
final class RokidBLETransport: NSObject, ObservableObject, RokidTransporting {

    // TODO(capture-validate): placeholder UUIDs — the community docs give characteristic
    // *names* only. Resolve from a BLE capture of the Rokid app once hardware is in hand.
    nonisolated(unsafe) static let writeCharUUID = CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB")
    nonisolated(unsafe) static let notifyCharUUID = CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB")
    nonisolated static let advertisedNamePrefix = "Rokid"

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
        guard name.hasPrefix(Self.advertisedNamePrefix) else { return }
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
