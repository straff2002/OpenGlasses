import WidgetKit
import SwiftUI
import AppIntents

/// Control Widget for the iPhone Action Button and Control Center.
/// Toggles wake-word listening via shared App Group state without opening the app.
@available(iOS 18.0, *)
struct ListeningControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.openglasses.app.ListeningControl") {
            ControlWidgetToggle(
                "Avenkin Listen",
                isOn: SharedAppState.isListening,
                action: SetListeningIntent()
            ) { isOn in
                Label {
                    Text(isOn ? "Listening" : "Listen")
                } icon: {
                    LogoIcon(size: 18)
                }
            }
            // The on-state tint: the brand accent, not the system default.
            .tint(AccentColors.aiCoral)
        }
        .displayName("Avenkin Listen")
        .description("Toggle wake-word listening in Avenkin.")
    }
}
