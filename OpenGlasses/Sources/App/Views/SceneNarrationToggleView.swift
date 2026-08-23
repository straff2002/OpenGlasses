import SwiftUI

/// The in-Settings control for continuous scene narration (Plan CV P2).
///
/// Two controls rather than one, because the feature genuinely has two halves and conflating them
/// is what makes continuous narration unbearable: **watching** is cheap-ish and silent (descriptions
/// accumulate as grounding, so a later question is answered against a scene the model has already
/// looked at), and **narrating** puts those descriptions in the wearer's ear. Turning the feature on
/// must not start talking.
///
/// P3 adds the honest half: a halt says why here *and* aloud, and hardware that can't run narration
/// at all says so instead of offering a switch that flips itself back.
@MainActor
struct SceneNarrationToggleView: View {
    @ObservedObject private var service = SceneNarrationService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Watch the scene", isOn: Binding(
                get: { service.mode != .off },
                set: { $0 ? service.start() : service.stop() }
            ))
            .tint(AppAccent.color)

            if service.mode != .off {
                Toggle("Speak descriptions aloud", isOn: Binding(
                    get: { service.mode == .narrating },
                    set: { $0 ? service.startNarrating() : service.stopNarrating() }
                ))
                .tint(AppAccent.color)

                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let reason = service.unavailableReason {
            // Plan CV P3: a start that can't happen says so, rather than a switch that flips back.
            Label(reason, systemImage: "video.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let halt = service.haltReason {
            // Plan CV P3 owns the full treatment — announcing the stop aloud and saying why. This
            // is the Settings half of the same debt: for a wearer relying on narration, silence
            // that isn't explained is indistinguishable from silence because nothing changed.
            Label(Self.haltCopy(halt), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let description = service.latestDescription {
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            Text("Watching…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func haltCopy(_ interruption: NarrationSessionPolicy.Interruption) -> String {
        switch interruption {
        case .backgrounded:
            return "Paused — on-device descriptions can't run while the app is in the background."
        case .cameraUnavailable:
            return "Paused — no live camera feed from the glasses."
        case .userTurn, .realtimeSession:
            // Not halts; the policy never reports these as a halt reason. Kept exhaustive so a new
            // interruption has to decide what the wearer is told.
            return "Paused."
        }
    }
}

#Preview {
    Form { SceneNarrationToggleView() }
}
