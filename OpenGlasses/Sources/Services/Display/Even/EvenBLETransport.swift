import CoreBluetooth
import Foundation

/// Plan AH — the app's first owned BLE stack, and the only device-gated piece of the EVEN
/// path. **Ships dark**: nothing reaches this class until the user pairs G2 lenses in
/// Settings and selects the EVEN backend, and every byte-level assumption (UUIDs, the
/// 7-packet auth handshake, characteristic roles) is a community reconstruction awaiting
/// hardware validation.
///
/// Decisions (named per plan): **foreground-only v1** — no `bluetooth-central` background
/// mode, no state restoration; consistent with the app's other lifecycle constraints.
/// Left/right lenses are separate peripherals (`Even G2_*`); frames are mirrored to both,
/// and a connected-left/missing-right session runs single-lens degraded.
@MainActor
final class EvenBLETransport: NSObject, ObservableObject, EvenTransporting {

    // Community-reconstructed UUIDs (base 00002760-08C2-11E1-9073-0E8AC72EXXXX).
    //
    // `nonisolated` because the CoreBluetooth delegate callbacks below read them before hopping
    // to the main actor — matching a UUID or an advertised name must not cost an actor hop on the
    // BLE callback queue. `CBUUID` isn't annotated `Sendable`, but these are immutable value
    // objects created once, so `nonisolated(unsafe)` states that rather than working around it.
    nonisolated(unsafe) static let writeCharUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5401")
    nonisolated(unsafe) static let notifyCharUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E5402")
    nonisolated(unsafe) static let renderCharUUID = CBUUID(string: "00002760-08C2-11E1-9073-0E8AC72E6402")
    nonisolated static let advertisedNamePrefix = "Even G2"

    var onEvent: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private var central: CBCentralManager?
    private var lenses: [CBPeripheral] = []
    private var renderCharacteristics: [ObjectIdentifier: CBCharacteristic] = [:]
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

    // MARK: - EvenTransporting

    var isConnected: Bool {
        !lenses.isEmpty && lenses.contains { $0.state == .connected }
            && !renderCharacteristics.isEmpty
    }

    func connect() async throws {
        guard Config.evenPairingConfigured else { throw GlassesDisplayError.noDisplay }
        if isConnected { return }
        ensureCentral()
        guard let central, central.state == .poweredOn else {
            throw GlassesDisplayError.sessionUnavailable
        }

        let ids = [Config.evenLeftPeripheralID, Config.evenRightPeripheralID]
            .compactMap { $0 }.compactMap(UUID.init(uuidString:))
        lenses = central.retrievePeripherals(withIdentifiers: ids)
        guard !lenses.isEmpty else { throw GlassesDisplayError.sessionUnavailable }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            for lens in lenses {
                lens.delegate = self
                central.connect(lens)
            }
            // 10 s connect deadline — a dead lens must not hang the render queue.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let pending = self.connectContinuation else { return }
                self.connectContinuation = nil
                pending.resume(throwing: GlassesDisplayError.sessionUnavailable)
            }
        }
        // NOTE: the community capture logs show a 7-packet app-level auth handshake after
        // connect. Its bytes are not reliably documented — implement from a capture once
        // hardware is in hand. Until then rendering may be rejected by the device; that
        // failure surfaces through sendRenderPacket's error path, honestly.
    }

    func disconnect() {
        connectContinuation?.resume(throwing: CancellationError())
        connectContinuation = nil
        for lens in lenses { central?.cancelPeripheralConnection(lens) }
        lenses = []
        renderCharacteristics = [:]
    }

    func sendRenderPacket(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw GlassesDisplayError.sessionUnavailable }
        let data = Data(bytes)
        // Mirror to every connected lens (single-lens degraded state included).
        for lens in lenses where lens.state == .connected {
            guard let characteristic = renderCharacteristics[ObjectIdentifier(lens)] else { continue }
            lens.writeValue(data, for: characteristic, type: .withoutResponse)
        }
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

extension EvenBLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {

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
            self.renderCharacteristics[ObjectIdentifier(peripheral)] = nil
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
                case Self.renderCharUUID:
                    self.renderCharacteristics[ObjectIdentifier(peripheral)] = characteristic
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
