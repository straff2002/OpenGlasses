import Foundation
import UIKit

/// Controls the device screen brightness.
struct BrightnessTool: NativeTool {
    let name = "brightness"
    let description = "Adjust the device screen brightness. Set to a specific level or use presets like 'max', 'min', 'half', 'dim', 'bright'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "level": [
                "type": "string",
                "description": "Brightness level: a number 0-100, or preset: 'max', 'min', 'half', 'dim', 'bright', 'up', 'down'"
            ]
        ],
        "required": ["level"]
    ]

    @MainActor
    private static func getScreenBrightness() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.brightness ?? 0.5
    }

    @MainActor
    private static func setScreenBrightness(_ value: CGFloat) {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.brightness = value
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let levelStr = args["level"] as? String, !levelStr.isEmpty else {
            let current = await MainActor.run { Int(Self.getScreenBrightness() * 100) }
            return "Current brightness: \(current)%. Tell me a level (0-100) or say max, min, half, dim, bright."
        }

        let currentBrightness = await MainActor.run { Self.getScreenBrightness() }
        let newBrightness: CGFloat

        switch levelStr.lowercased().trimmingCharacters(in: .whitespaces) {
        case "max", "maximum", "full", "100":
            newBrightness = 1.0
        case "min", "minimum", "lowest", "0":
            newBrightness = 0.0
        case "half", "medium", "50":
            newBrightness = 0.5
        case "dim", "low":
            newBrightness = 0.2
        case "bright", "high":
            newBrightness = 0.85
        case "up":
            newBrightness = min(1.0, currentBrightness + 0.2)
        case "down":
            newBrightness = max(0.0, currentBrightness - 0.2)
        default:
            // Try parsing as a number (0-100)
            if let value = Double(levelStr.replacingOccurrences(of: "%", with: "")) {
                newBrightness = CGFloat(max(0, min(100, value)) / 100.0)
            } else {
                return "Couldn't understand '\(levelStr)'. Use a number 0-100 or say max, min, half, dim, bright, up, down."
            }
        }

        await MainActor.run {
            Self.setScreenBrightness(newBrightness)
        }

        let pct = Int(newBrightness * 100)
        return "Brightness set to \(pct)%."
    }
}
