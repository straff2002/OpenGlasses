import Foundation
import WidgetKit

/// Cross-process state shared between the app and its widget/control extension.
///
/// Backed by `UserDefaults(suiteName: "group.com.openglasses.app")` so writes from the
/// widget process are immediately visible to the app. A Darwin notification is posted on
/// every write so an alive (background or foreground) app process can react instantly.
enum SharedAppState {
    static let appGroup = "group.com.openglasses.app"
    static let listeningChangedNotification = "com.openglasses.app.listening-changed"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var isListening: Bool {
        // Absent means "never toggled", and the app's default for that is ON (`Config.listeningEnabled`).
        // `bool(forKey:)` answered false here, so a fresh install rendered the Control as off and a
        // press from that state wrote a real `false` into the App Group — listening silently disabled.
        get { defaults.object(forKey: "listeningEnabled") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "listeningEnabled")
            postListeningChanged()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func postListeningChanged() {
        let name = CFNotificationName(listeningChangedNotification as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil, nil, true
        )
    }
}
