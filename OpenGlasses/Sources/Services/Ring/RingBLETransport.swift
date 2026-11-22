#if !AVENKIN_PHONE_ONLY
import CoreBluetooth
import Foundation

/// The ring's Bluetooth link (Plan MZ §7): its own `CBCentralManager`, never shared with the
/// display's (`EvenBLETransport`).
///
/// - **Find.** Scans for the family's advertised service and keeps only what the driver recognises,
///   by advertised name or by the company identifier at the start of the manufacturer data —
///   never by an address. Also asks for rings already connected for the protocol service: a ring
///   the ring's own app holds does not advertise, but can be found that way (decision 9).
/// - **Pair.** The CoreBluetooth identifier of the ring the wearer picked is the paired ring. On
///   connect the protocol and battery services are discovered and notifications subscribed; only
///   then is `.ready` reported and anything forwarded. Some attributes need pairing, so iOS shows
///   its pairing prompt on the first connect; the subscription completes once it is answered.
/// - **Stay.** A connect is a pending one: iOS completes it when the ring is in range. The service
///   reconnects after a drop with a short backoff while the app runs, using the existing
///   `bluetooth-central` background mode (decision 3). No state restoration in v1.
///
/// The central is made on first use, so Bluetooth is never touched (and never asked for) until the
/// ring support is on and the wearer pairs a ring or one is paired.
@MainActor
final class RingBLETransport: NSObject, RingTransporting {

    var onEvent: ((RingTransportEvent) -> Void)?

    private let driver: RingDriver
    private let serviceUUID: CBUUID
    private let writeUUID: CBUUID
    private let notifyUUID: CBUUID
    private let batteryServiceUUID: CBUUID?
    private let batteryLevelUUID: CBUUID?
    private let advertisedServiceUUID: CBUUID

    private var central: CBCentralManager?
    private var wantsScan = false
    private var wantedPeripheral: UUID?
    private var seen: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var reportedReady = false

    init(driver: RingDriver = SmartRingDriver()) {
        self.driver = driver
        serviceUUID = CBUUID(string: driver.gatt.service)
        writeUUID = CBUUID(string: driver.gatt.write)
        notifyUUID = CBUUID(string: driver.gatt.notify)
        batteryServiceUUID = driver.gatt.batteryService.map(CBUUID.init(string:))
        batteryLevelUUID = driver.gatt.batteryLevel.map(CBUUID.init(string:))
        advertisedServiceUUID = CBUUID(string: driver.advertisedService)
        super.init()
    }

    // MARK: - RingTransporting

    func startScan() {
        wantsScan = true
        ensureCentral()
        beginScanIfReady()
    }

    func stopScan() {
        wantsScan = false
        central?.stopScan()
    }

    func connect(to identifier: UUID) {
        wantedPeripheral = identifier
        ensureCentral()
        connectIfReady()
    }

    func disconnect() {
        wantedPeripheral = nil
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        clearLink()
    }

    func write(_ bytes: [UInt8]) {
        guard let peripheral, let writeCharacteristic, peripheral.state == .connected else { return }
        peripheral.writeValue(Data(bytes), for: writeCharacteristic,
                              type: driver.gatt.writeWithResponse ? .withResponse : .withoutResponse)
    }

    func readBattery() {
        guard let peripheral, let batteryCharacteristic, peripheral.state == .connected else {
            onEvent?(.battery(nil))
            return
        }
        peripheral.readValue(for: batteryCharacteristic)
    }

    // MARK: - Internals

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [advertisedServiceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // A ring the ring's own app holds is connected already and does not advertise.
        for held in central.retrieveConnectedPeripherals(withServices: [serviceUUID]) {
            seen[held.identifier] = held
            onEvent?(.discovered(RingScanMatch.connectedCandidate(id: held.identifier)))
        }
    }

    private func connectIfReady() {
        guard let wantedPeripheral, let central, central.state == .poweredOn else { return }
        let target = seen[wantedPeripheral]
            ?? central.retrievePeripherals(withIdentifiers: [wantedPeripheral]).first
        guard let target else {
            onEvent?(.disconnected)
            return
        }
        if peripheral !== target { clearLink() }
        peripheral = target
        target.delegate = self
        if target.state == .connected {
            discoverServices(on: target)
        } else if target.state != .connecting {
            central.connect(target, options: nil)
        }
    }

    private func discoverServices(on peripheral: CBPeripheral) {
        var services = [serviceUUID]
        if let batteryServiceUUID { services.append(batteryServiceUUID) }
        peripheral.discoverServices(services)
    }

    private func clearLink() {
        writeCharacteristic = nil
        batteryCharacteristic = nil
        reportedReady = false
        peripheral?.delegate = nil
        peripheral = nil
    }

    fileprivate static func radioState(_ state: CBManagerState) -> RingRadioState {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff, .resetting: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

// CoreBluetooth calls these on the main queue (the central was made with `queue: .main`), so each
// one runs on the main actor in arrival order: the ring's packets must stay in sequence.
extension RingBLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            onEvent?(.radio(Self.radioState(central.state)))
            guard central.state == .poweredOn else { return }
            beginScanIfReady()
            connectIfReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let advertisement = RingScanMatch.advertisement(from: advertisementData,
                                                            peripheralName: peripheral.name)
            guard let candidate = RingScanMatch.candidate(id: peripheral.identifier,
                                                          advertisement: advertisement, driver: driver)
            else { return }
            seen[peripheral.identifier] = peripheral
            onEvent?(.discovered(candidate))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            discoverServices(on: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            clearLink()
            onEvent?(.disconnected)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            clearLink()
            onEvent?(.disconnected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            for service in peripheral.services ?? [] {
                if service.uuid == serviceUUID {
                    peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
                } else if let batteryServiceUUID, service.uuid == batteryServiceUUID,
                          let batteryLevelUUID {
                    peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            for characteristic in service.characteristics ?? [] {
                let uuid = characteristic.uuid
                if uuid == writeUUID {
                    writeCharacteristic = characteristic
                } else if uuid == notifyUUID {
                    // May bring up the iOS pairing prompt; the answer arrives as the state update.
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if let batteryLevelUUID, uuid == batteryLevelUUID {
                    batteryCharacteristic = characteristic
                }
            }
            reportReadyIfLinked(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, characteristic.uuid == notifyUUID else { return }
            if error != nil || !characteristic.isNotifying {
                // Pairing refused or the subscription failed: nothing works without it.
                if let central { central.cancelPeripheralConnection(peripheral) }
                return
            }
            reportReadyIfLinked(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if characteristic.uuid == notifyUUID {
                guard reportedReady, error == nil, let value = characteristic.value else { return }
                onEvent?(.notification([UInt8](value)))
            } else if let batteryLevelUUID, characteristic.uuid == batteryLevelUUID {
                let level = error == nil ? characteristic.value?.first.map(Int.init) : nil
                onEvent?(.battery(level))
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        // The echo is the acknowledgement; a failed write is retried by the sync machine's timer.
    }

    private func reportReadyIfLinked(_ peripheral: CBPeripheral) {
        guard !reportedReady, writeCharacteristic != nil,
              let notify = peripheral.services?.first(where: { $0.uuid == serviceUUID })?
                .characteristics?.first(where: { $0.uuid == notifyUUID }),
              notify.isNotifying else { return }
        reportedReady = true
        onEvent?(.ready)
    }
}

extension RingService {
    /// The service the app runs: Bluetooth, Apple Health and the wearer's settings.
    static func live() -> RingService {
        RingService(transport: RingBLETransport(), healthStore: HealthKitRingStore(),
                    posture: { PowerPolicyService.shared.posture })
    }
}

#endif
