import Foundation
import UIKit

/// Native tool for launching Asian messaging and social apps.
/// Covers KakaoTalk (Korea), LINE (Japan/Thailand/Taiwan), and Zalo (Vietnam).
struct AsianMessagingTool: NativeTool {
    let name = "asian_messaging"
    let description = """
        Open Asian messaging apps: KakaoTalk (카카오톡, Korea), LINE (Japan/Thailand/Taiwan), \
        Zalo (Vietnam). Use when the user asks to open or send a message via these apps.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app": [
                "type": "string",
                "description": "App name: 'kakaotalk', 'line', 'zalo'",
                "enum": ["kakaotalk", "line", "zalo"]
            ]
        ],
        "required": ["app"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard AIFeatureGate.isEnabled(.messaging) else {
            return AIFeatureGate.disabledMessage(.messaging)
        }
        guard let appName = args["app"] as? String else {
            return "Please specify the app name."
        }

        let urlString: String
        let displayName: String

        switch appName.lowercased() {
        case "kakaotalk", "kakao":
            displayName = "KakaoTalk"
            urlString = "kakaotalk://"
        case "line":
            displayName = "LINE"
            urlString = "line://"
        case "zalo":
            displayName = "Zalo"
            urlString = "zalo://"
        default:
            return "Unsupported app: \(appName). Supported: KakaoTalk, LINE, Zalo."
        }

        guard let url = URL(string: urlString) else {
            return "Could not open \(displayName)."
        }

        let canOpen = await MainActor.run { UIApplication.shared.canOpenURL(url) }

        if canOpen {
            await MainActor.run {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return "Opening \(displayName)."
        } else {
            return "\(displayName) is not installed."
        }
    }
}
