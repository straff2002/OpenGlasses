import SwiftUI

/// The in-Settings control for continuous scene narration (Plan CV P2).
///
/// Two controls rather than one, because the feature genuinely has two halves and conflating them
/// is what makes continuous narration unbearable: **watching** is cheap-ish and silent (descriptions
/// accumulate as grounding, so a later question is answered against a scene the model has already
/// looked at), and **narrating** puts those descriptions in the wearer's ear. Turning the feature on
/// must not start talking.
///
/// P3 added the honest half: a halt says why here *and* aloud, and hardware that can't run
/// narration at all says so instead of offering a switch that flips itself back.
///
/// The caption/narration decision added a third status line with the same job: live ambient
/// captions take the ear while the loop keeps watching, and a wearer who left captions on this
/// morning must be able to see why narration has gone quiet rather than conclude it is broken.
///
/// And a fourth, for the camera the first switch now starts: it comes up in seconds, not instantly,
/// and a switch that appears to do nothing for twenty seconds is the same failure in yet another
/// costume.
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
        if service.isStartingCamera {
            // Plan CV, camera ownership: narration turns the glasses camera on, and the cold start
            // is device-traced at up to ~20 s. An unlabelled wait that long is indistinguishable
            // from a broken switch — the same observation that produced the "Starting…" state on
            // the Camera button, arriving here for the same reason.
            Label("Starting the camera — this takes a few seconds.",
                  systemImage: "video.badge.ellipsis")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let reason = service.unavailableReason {
            // Plan CV P3: a start that can't happen says so, rather than a switch that flips back.
            Label(reason, systemImage: "video.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let halt = service.haltReason {
            // The Settings half of a debt narration also pays aloud: for a wearer relying on it,
            // silence that isn't explained is indistinguishable from silence because nothing
            // changed. The spoken announcement happens too — `NarrationVoiceNotices` decides who
            // hears it — and this line is what remains visible after it has been said.
            Label(Self.haltCopy(halt), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let silence = service.silenceReason {
            // Still watching, just not talking. A different symbol from the halt on purpose: this
            // is not something being broken, it is two features being polite to each other, and
            // the copy has to name the switch that undoes it.
            Label(Self.silenceCopy(silence), systemImage: "speaker.slash")
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
        case .userTurn, .realtimeSession, .ambientCaptions:
            // Not halts; the policy never reports these as a halt reason. Kept exhaustive so a new
            // interruption has to decide what the wearer is told.
            return "Paused."
        }
    }

    /// Copy for a standing condition that takes the ear without stopping the loop. Shorter than
    /// the spoken version because the switch it names is a few rows away on this screen.
    static func silenceCopy(_ interruption: NarrationSessionPolicy.Interruption) -> String {
        switch interruption {
        case .ambientCaptions:
            return "Quiet while live captions are running — still watching, so questions are still answered."
        case .userTurn, .realtimeSession:
            // Moments, not standing conditions; the policy never reports these here.
            return "Quiet for a moment."
        case .backgrounded, .cameraUnavailable:
            return Self.haltCopy(interruption)
        }
    }
}

#Preview {
    Form { SceneNarrationToggleView() }
}
