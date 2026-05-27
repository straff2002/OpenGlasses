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
                "OpenGlasses Listen",
                isOn: SharedAppState.isListening,
                action: SetListeningIntent()
            ) { isOn in
                Label {
                    Text(isOn ? "Listening" : "Listen")
                } icon: {
                    LogoIcon(size: 18)
                }
            }
        }
        .displayName("OpenGlasses Listen")
        .description("Toggle wake-word listening in OpenGlasses.")
    }
}
