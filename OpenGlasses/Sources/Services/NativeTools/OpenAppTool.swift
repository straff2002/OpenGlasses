import Foundation
import UIKit

/// Opens iOS apps by name using URL schemes.
struct OpenAppTool: NativeTool {
    let name = "open_app"
    let description = "Open an iOS app by name. Supports Apple built-in apps and popular third-party apps."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "app_name": [
                "type": "string",
                "description": "The name of the app to open, e.g. 'Podcasts', 'Music', 'Maps', 'YouTube'"
            ]
        ],
        "required": ["app_name"]
    ]

    private static let appSchemes: [String: String] = [
        // Apple built-in apps
        "podcasts": "podcasts://",
        "apple podcasts": "podcasts://",
        "music": "music://",
        "maps": "maps://",
        "safari": "https://",
        "phone": "tel://",
        "messages": "sms://",
        "mail": "mailto:",
        "calendar": "calshow://",
        "camera": "camera://",
        "photos": "photos-redirect://",
        "settings": "App-prefs://",
        "weather": "weather://",
        "notes": "mobilenotes://",
        "reminders": "x-apple-reminderkit://",
        "clock": "clock-alarm://",
        "timer": "clock-alarm://",
        "app store": "itms-apps://",
        "facetime": "facetime://",
        "shortcuts": "shortcuts://",
        "health": "x-apple-health://",
        "wallet": "shoebox://",
        "files": "shareddocuments://",
        "news": "applenews://",
        "stocks": "stocks://",
        "voice memos": "voicememos://",
        "translate": "translate://",
        "fitness": "fitnessapp://",
        "home": "com.apple.home://",
        // Popular third-party apps
        "youtube": "youtube://",
        "spotify": "spotify://",
        "tidal": "tidal://",
        "amazon music": "amznmp3://",
        "whatsapp": "whatsapp://",
        "instagram": "instagram://",
        "x": "twitter://",
        "twitter": "twitter://",
        "google maps": "comgooglemaps://",
        "telegram": "tg://",
        "reddit": "reddit://",
        "tiktok": "snssdk1233://",
        "netflix": "nflx://",
        "uber": "uber://",
        "lyft": "lyft://",
    ]

    /// Common speech-to-text misrecognitions → correct app name
    private static let speechAliases: [String: String] = [
        "opencast": "podcasts",
        "open cast": "podcasts",
        "pod cast": "podcasts",
        "podcast": "podcasts",
        "the podcasts app": "podcasts",
        "the music app": "music",
        "tidal music": "tidal",
        "title": "tidal",
        "amazon": "amazon music",
        "amazon prime music": "amazon music",
        "the maps app": "maps",
        "google map": "google maps",
        "facetiming": "facetime",
        "what's app": "whatsapp",
        "what sapp": "whatsapp",
        "tick tock": "tiktok",
        "tick-tock": "tiktok",
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let appName = args["app_name"] as? String, !appName.isEmpty else {
            return "No app name provided."
        }

        let rawKey = appName.lowercased().trimmingCharacters(in: .whitespaces)
        // Resolve speech misrecognitions
        let key = Self.speechAliases[rawKey] ?? rawKey

        guard let scheme = Self.appSchemes[key],
              let url = URL(string: scheme) else {
            let available = Self.appSchemes.keys.sorted().joined(separator: ", ")
            return "I don't know how to open \(appName). Try asking for a specific app like Podcasts, Music, Maps, etc. Supported apps: \(available)"
        }

        // Open directly rather than asking `canOpenURL` first: the pre-check only answers for the
        // fifty schemes iOS honours in `LSApplicationQueriesSchemes`, while `open` takes any scheme
        // and reports whether an installed app accepted it. The table above can grow freely.
        let opened = await Self.open(url)

        guard opened else {
            return "\(appName) doesn't appear to be installed on this device."
        }

        let displayName = appName.prefix(1).uppercased() + appName.dropFirst()
        // Plan LA: an app opened is handed over, never done.
        ActionCompletionReport.record(.partial(reason: .handedToApp))
        return "Opening \(displayName)..."
    }

    @MainActor
    private static func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { continuation.resume(returning: $0) }
        }
    }
}
