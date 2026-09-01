import Foundation
import HomeKit

/// Controls smart home devices via Apple HomeKit.
/// Supports lights, switches, thermostats, locks, and scene activation.
final class HomeKitTool: NativeTool, @unchecked Sendable {
    let name = "smart_home"
    let description = "Control smart home devices via HomeKit. Turn lights on/off, adjust brightness/color temperature, set thermostat, lock/unlock doors, or activate scenes."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'on', 'off', 'toggle', 'set', 'brightness', 'temperature', 'lock', 'unlock', 'scene', 'list', 'list_scenes'",
            ],
            "device": [
                "type": "string",
                "description": "Device or room name (e.g. 'living room lights', 'bedroom fan', 'front door'). Fuzzy matched.",
            ],
            "value": [
                "type": "string",
                "description": "Value for 'set'/'brightness'/'temperature' actions (e.g. '75' for brightness %, '72' for thermostat °F, 'warm' for color temp)",
            ],
        ],
        "required": ["action"],
    ]

    /// Single shared HomeKit manager — persists for the app lifetime.
    /// Initialized lazily but always on the main thread.
    private static var _shared: HomeKitManager?
    private static var shared: HomeKitManager {
        if let existing = _shared { return existing }
        // This should be called from main thread via prepareShared()
        let manager = HomeKitManager()
        _shared = manager
        return manager
    }

    /// Call from AppState init on the main thread to avoid lazy init issues.
    @MainActor
    static func prepareShared() {
        _ = shared
    }

    init() {}

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action specified. Use 'on', 'off', 'toggle', 'set', 'brightness', 'temperature', 'lock', 'unlock', 'scene', 'list', or 'list_scenes'."
        }

        // Ensure HomeKit is initialized on main thread
        await MainActor.run { Self.prepareShared() }
        let manager = Self.shared
        await manager.ensureReady()

        guard let homeManager = manager.homeManager else {
            return "HomeKit initialization failed. Please try again."
        }

        let authStatus = homeManager.authorizationStatus
        PrivacyLog.homeBridge(.homeKit, .authorizationChanged, status: Int(authStatus.rawValue),
                              count: homeManager.homes.count)
        // Accept if authorized OR if we have homes (auth may lag behind on some iOS versions)
        if !authStatus.contains(.authorized) && homeManager.homes.isEmpty {
            return "HomeKit access not authorized. Please enable Home Data for OpenGlasses in Settings → Privacy & Security → HomeKit. (Auth status: \(authStatus.rawValue))"
        }

        // Homes may not have loaded yet — retry a few times
        var home: HMHome? = homeManager.homes.first
        if home == nil {
            for attempt in 1...3 {
                PrivacyLog.homeBridge(.homeKit, .waitingForHomes, attempt: attempt)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                home = homeManager.homes.first
                if home != nil { break }
            }
        }
        guard let home else {
            PrivacyLog.homeBridge(.homeKit, .homesUnavailable,
                                  status: Int(homeManager.authorizationStatus.rawValue))
            return "No HomeKit home found. Open the Apple Home app and make sure you have a home set up with accessories."
        }

        let deviceName = (args["device"] as? String)?.lowercased() ?? ""
        let value = args["value"] as? String ?? ""

        switch action.lowercased() {
        case "list":
            return listDevices(home: home)
        case "list_scenes":
            return listScenes(home: home)
        case "scene":
            return await activateScene(home: home, sceneName: deviceName.isEmpty ? value : deviceName)
        case "on", "off", "toggle":
            return await controlPower(home: home, deviceName: deviceName, action: action.lowercased())
        case "brightness":
            return await setBrightness(home: home, deviceName: deviceName, value: value)
        case "temperature":
            return await setThermostat(home: home, deviceName: deviceName, value: value)
        case "lock":
            return await setLock(home: home, deviceName: deviceName, locked: true)
        case "unlock":
            return await setLock(home: home, deviceName: deviceName, locked: false)
        case "set":
            if let intValue = Int(value), intValue >= 0 && intValue <= 100 {
                return await setBrightness(home: home, deviceName: deviceName, value: value)
            }
            return await controlPower(home: home, deviceName: deviceName, action: "on")
        default:
            return "Unknown action '\(action)'. Use 'on', 'off', 'toggle', 'brightness', 'temperature', 'lock', 'unlock', 'scene', or 'list'."
        }
    }

    // MARK: - List

    private func listDevices(home: HMHome) -> String {
        var result: [String] = []
        for room in home.rooms {
            let accessories = room.accessories.map { acc -> String in
                let state = getPowerState(acc) ?? "unknown"
                let reachable = acc.isReachable ? "" : " [offline]"
                return "\(acc.name) (\(state)\(reachable))"
            }
            if !accessories.isEmpty {
                result.append("\(room.name): \(accessories.joined(separator: ", "))")
            }
        }
        if result.isEmpty {
            return "No devices found in '\(home.name)'. Add devices via the Apple Home app."
        }
        return "Home: \(home.name). \(result.joined(separator: ". "))"
    }

    private func listScenes(home: HMHome) -> String {
        let scenes = home.actionSets.map { $0.name }
        if scenes.isEmpty {
            return "No scenes set up. Create scenes in the Apple Home app."
        }
        return "Available scenes: \(scenes.joined(separator: ", "))"
    }

    // MARK: - Power Control

    private func controlPower(home: HMHome, deviceName: String, action: String) async -> String {
        guard let (accessory, characteristic) = findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeLightbulb, characteristicType: HMCharacteristicTypePowerState)
            ?? findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeSwitch, characteristicType: HMCharacteristicTypePowerState)
            ?? findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeFan, characteristicType: HMCharacteristicTypePowerState)
            ?? findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeOutlet, characteristicType: HMCharacteristicTypePowerState)
        else {
            return "Couldn't find a controllable device matching '\(deviceName)'. Say 'list' to see available devices."
        }

        guard accessory.isReachable else {
            return "\(accessory.name) is not reachable. The device may be offline or disconnected from the network."
        }

        // Read current value first — some accessories require this before writes
        do {
            try await characteristic.readValue()
        } catch {
            PrivacyLog.homeBridge(.homeKit, .readBeforeWriteFailed,
                                  error: SafeErrorSummary(error))
        }

        let newValue: Bool
        if action == "toggle" {
            let current = characteristic.value as? Bool ?? false
            newValue = !current
        } else {
            newValue = (action == "on")
        }

        do {
            try await characteristic.writeValue(newValue)
            return "\(accessory.name) turned \(newValue ? "on" : "off")."
        } catch {
            return "Failed to control \(accessory.name): \(error.localizedDescription). Is the device reachable? (reachable=\(accessory.isReachable))"
        }
    }

    // MARK: - Brightness

    private func setBrightness(home: HMHome, deviceName: String, value: String) async -> String {
        guard let brightness = Int(value), brightness >= 0 && brightness <= 100 else {
            return "Brightness must be a number between 0 and 100."
        }

        guard let (accessory, characteristic) = findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeLightbulb, characteristicType: HMCharacteristicTypeBrightness) else {
            return "Couldn't find a dimmable light matching '\(deviceName)'."
        }

        guard accessory.isReachable else {
            return "\(accessory.name) is not reachable. The device may be offline."
        }

        do {
            try await characteristic.readValue()
            if let powerChar = findCharacteristic(accessory: accessory, serviceType: HMServiceTypeLightbulb, characteristicType: HMCharacteristicTypePowerState) {
                try await powerChar.writeValue(true)
            }
            try await characteristic.writeValue(brightness)
            return "\(accessory.name) brightness set to \(brightness)%."
        } catch {
            return "Failed to set brightness: \(error.localizedDescription)"
        }
    }

    // MARK: - Thermostat

    private func setThermostat(home: HMHome, deviceName: String, value: String) async -> String {
        guard let temp = Double(value) else {
            return "Temperature must be a number (e.g. '72' for 72 degrees Fahrenheit)."
        }

        let celsius = (temp - 32) * 5.0 / 9.0

        guard let (accessory, characteristic) = findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeThermostat, characteristicType: HMCharacteristicTypeTargetTemperature) else {
            return "Couldn't find a thermostat matching '\(deviceName)'."
        }

        do {
            try await characteristic.writeValue(celsius)
            return "\(accessory.name) set to \(Int(temp)) degrees Fahrenheit."
        } catch {
            return "Failed to set thermostat: \(error.localizedDescription)"
        }
    }

    // MARK: - Lock

    private func setLock(home: HMHome, deviceName: String, locked: Bool) async -> String {
        guard let (accessory, characteristic) = findAccessory(home: home, name: deviceName, serviceType: HMServiceTypeLockMechanism, characteristicType: HMCharacteristicTypeTargetLockMechanismState) else {
            return "Couldn't find a lock matching '\(deviceName)'."
        }

        guard accessory.isReachable else {
            return "\(accessory.name) is not reachable. The device may be offline."
        }

        let lockValue = locked ? HMCharacteristicValueLockMechanismState.secured.rawValue : HMCharacteristicValueLockMechanismState.unsecured.rawValue

        do {
            try await characteristic.readValue()
            try await characteristic.writeValue(lockValue)
            return "\(accessory.name) \(locked ? "locked" : "unlocked")."
        } catch {
            return "Failed to \(locked ? "lock" : "unlock"): \(error.localizedDescription)"
        }
    }

    // MARK: - Scenes

    private func activateScene(home: HMHome, sceneName: String) async -> String {
        let target = sceneName.lowercased()
        guard let scene = home.actionSets.first(where: { $0.name.lowercased().contains(target) }) else {
            let available = home.actionSets.map { $0.name }.joined(separator: ", ")
            return "No scene matching '\(sceneName)'. Available: \(available.isEmpty ? "none" : available)"
        }

        do {
            try await home.executeActionSet(scene)
            return "Scene '\(scene.name)' activated."
        } catch {
            return "Failed to activate '\(scene.name)': \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func findAccessory(home: HMHome, name: String, serviceType: String, characteristicType: String) -> (HMAccessory, HMCharacteristic)? {
        let target = name.lowercased()
        let allAccessories = home.accessories
        let candidates = allAccessories.filter { acc in
            let accName = acc.name.lowercased()
            let roomName = acc.room?.name.lowercased() ?? ""
            return accName.contains(target) || target.contains(accName) ||
                roomName.contains(target) || "\(roomName) \(accName)".contains(target)
        }

        let searchList = candidates.isEmpty ? allAccessories : candidates

        for accessory in searchList {
            if let characteristic = findCharacteristic(accessory: accessory, serviceType: serviceType, characteristicType: characteristicType) {
                return (accessory, characteristic)
            }
        }
        return nil
    }

    private func findCharacteristic(accessory: HMAccessory, serviceType: String, characteristicType: String) -> HMCharacteristic? {
        for service in accessory.services where service.serviceType == serviceType {
            for char in service.characteristics where char.characteristicType == characteristicType {
                return char
            }
        }
        return nil
    }

    private func getPowerState(_ accessory: HMAccessory) -> String? {
        for service in accessory.services {
            for char in service.characteristics where char.characteristicType == HMCharacteristicTypePowerState {
                if let on = char.value as? Bool {
                    return on ? "on" : "off"
                }
            }
        }
        return nil
    }
}

// MARK: - Shared HomeKit Manager

/// Singleton that holds the HMHomeManager for the app's lifetime.
/// Properly handles the async delegate callback race condition.
private class HomeKitManager: NSObject, HMHomeManagerDelegate {
    var homeManager: HMHomeManager?
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        // HMHomeManager MUST be created on the main thread
        assert(Thread.isMainThread, "HomeKitManager must be initialized on the main thread")
        let manager = HMHomeManager()
        manager.delegate = self
        self.homeManager = manager
        PrivacyLog.homeBridge(.homeKit, .managerInitialized)
    }

    func ensureReady() async {
        if isReady { return }

        // Wait for the delegate callback or timeout
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isReady {
                continuation.resume()
                return
            }
            waiters.append(continuation)

            // Timeout after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                // If still waiting, force-resume
                if !self.isReady {
                    self.isReady = true
                    PrivacyLog.homeBridge(.homeKit, .homesTimedOut)
                    for waiter in self.waiters {
                        waiter.resume()
                    }
                    self.waiters.removeAll()
                }
            }
        }
    }

    // HMHomeManagerDelegate
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        PrivacyLog.homeBridge(.homeKit, .homesUpdated,
                              status: Int(manager.authorizationStatus.rawValue),
                              count: manager.homes.count)
        isReady = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        PrivacyLog.homeBridge(.homeKit, .authorizationChanged, status: Int(status.rawValue))
        if status.contains(.authorized) && !isReady {
            // Auth granted — homes should follow shortly, but mark ready if we have homes
            if !manager.homes.isEmpty {
                isReady = true
                for waiter in waiters {
                    waiter.resume()
                }
                waiters.removeAll()
            }
        }
    }
}
