import Foundation
import UIKit

/// Reports device battery level, low power mode, and storage info — and, outside the phone-only
/// build, the in-lens Display's state (`DisplayStatusWording`): connected, switched on, whose the
/// lens is, and how the last send ended. State only, never what was shown.
struct DeviceInfoTool: NativeTool {
    let name = "device_info"
    #if AVENKIN_PHONE_ONLY
    let description = "Get device information: battery level, low power mode status, and available storage."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]
    #else
    let description = "Get device information: phone battery level, low power mode status and available storage, "
        + "and the in-lens display (HUD): whether display glasses are connected, whether the HUD is switched on, "
        + "whether the lens is free or in use by another app, and whether the last thing sent reached it. "
        + "Use it to answer 'is the display / HUD connected?'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "about": [
                "type": "string",
                "enum": ["phone", "display"],
                "description": "Optional: 'phone' for battery, power and storage only; 'display' for the in-lens display only. Omit for both."
            ]
        ] as [String: Any],
        "required": [] as [String]
    ]
    #endif

    /// Which part of the answer was asked for. Anything else (or nothing) is both.
    enum Part: Equatable {
        case phone, display, both

        init(argument: Any?) {
            switch (argument as? String)?.lowercased() {
            case "phone": self = .phone
            case "display", "hud": self = .display
            default: self = .both
            }
        }

        var includesPhone: Bool { self != .display }
        var includesDisplay: Bool { self != .phone }
    }

    func execute(args: [String: Any]) async throws -> String {
        let part = Part(argument: args["about"])
        var info: [String] = []
        if part.includesPhone { info += await phoneLines() }
        #if !AVENKIN_PHONE_ONLY
        if part.includesDisplay, let reading = await MainActor.run(body: { Self.displayReading() }) {
            info += DisplayStatusWording.lines(reading)
        }
        #endif
        return info.isEmpty ? "Couldn't retrieve device info." : info.joined(separator: ". ") + "."
    }

    #if !AVENKIN_PHONE_ONLY
    /// The Display's state, read now. Nil before AppState exists.
    @MainActor
    static func displayReading() -> DisplayStatusReading? {
        guard let appState = AppStateProvider.shared else { return nil }
        let display = appState.glassesDisplay
        let enabled = Config.glassesDisplayEnabled
        let hasDisplay = display.deviceSupportsDisplay()
        return DisplayStatusReading(
            backend: Config.displayBackend == .evenG2 ? .evenG2 : .metaDisplay,
            glassesPhase: appState.glassesPhase,
            hasDisplay: hasDisplay,
            hudEnabled: enabled,
            // `practiceAvailability` reads now (the published reading changes only on link and
            // session events); it is `.off` while the switch is off, which is worded separately.
            availability: display.practiceAvailability,
            worn: appState.glassesService.isWorn,
            dismissedByWearer: display.lensDismissed,
            lastSend: display.lastSend)
    }
    #endif

    private func phoneLines() async -> [String] {
        var info: [String] = []

        // Battery
        let batteryInfo = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let state = UIDevice.current.batteryState
            return (level, state)
        }

        let level = batteryInfo.0
        let state = batteryInfo.1

        if level >= 0 {
            let pct = Int(level * 100)
            var batteryStr = "Battery: \(pct)%"
            switch state {
            case .charging: batteryStr += " (charging)"
            case .full: batteryStr += " (fully charged)"
            case .unplugged: break
            default: break
            }
            info.append(batteryStr)
        }

        // Low Power Mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            info.append("Low Power Mode is ON")
        }

        // Power posture (Plan BV): the app's current battery/thermal-aware posture, when it's
        // doing anything (a one-line reason, e.g. "conserving — glasses battery 18%"). Silent in
        // the normal posture so device_info stays terse when there's nothing to economise.
        if let posture = await MainActor.run(body: { PowerPolicyService.shared.explanation }) {
            info.append("Power posture: \(posture)")
        }

        // Storage
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            let gb = Double(freeSpace) / 1_073_741_824.0
            info.append(String(format: "Available storage: %.1f GB", gb))
        }
        return info
    }
}
