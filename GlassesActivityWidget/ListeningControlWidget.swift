import WidgetKit
import SwiftUI
import AppIntents

// Controls render out of process: a control's icon must be an SF Symbol or a *symbol* image from
// this extension's asset catalog. An arbitrary SwiftUI view (`LogoIcon`) or a plain vector image
// (`AvenkinMark`) draws nothing there. `AvenkinSymbol` is the mark as a symbol template, copied
// into `GlassesActivityWidget/Assets.xcassets` from the app's catalog (the two are kept identical
// by `ControlWidgetGuardTests`).

/// Control for the iPhone Action Button and Control Center: turns wake-word listening on or off
/// via shared App Group state, without opening the app.
///
/// The kind string is a stored identifier — a wearer's Action button assignment points at it — so
/// it never changes, whatever the control is called.
@available(iOS 18.0, *)
struct ListeningControlWidget: ControlWidget {
    static let kind = "com.openglasses.app.ListeningControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetToggle(
                "Avenkin Listening",
                isOn: SharedAppState.isListening,
                action: SetListeningIntent()
            ) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "waveform" : "waveform.slash")
            }
            // The on-state tint: the brand accent, not the system default.
            .tint(AccentColors.aiCoral)
        }
        .displayName("Avenkin Listening")
        .description("Turn wake-word listening on or off. Avenkin stays in the background.")
    }
}

/// Control for the iPhone Action Button and Control Center: opens Avenkin and starts listening
/// straight away, no wake word — the hands-free launcher. See `AskAvenkinControlIntent`.
@available(iOS 18.0, *)
struct AskAvenkinControlWidget: ControlWidget {
    static let kind = "com.openglasses.app.AskControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: AskAvenkinControlIntent()) {
                Label("Ask Avenkin", image: "AvenkinSymbol")
            }
            .tint(AccentColors.aiCoral)
        }
        .displayName("Ask Avenkin")
        .description("Open Avenkin and start listening right away, without the wake word.")
    }
}
