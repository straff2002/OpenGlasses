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
        get { defaults.bool(forKey: "listeningEnabled") }
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
