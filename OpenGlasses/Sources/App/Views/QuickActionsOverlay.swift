import SwiftUI
import UIKit

/// Horizontal row of quick action buttons shown below the status ring.
///
/// Currently unreferenced: the control dock absorbed these into its one tile idiom (`BarButton`).
/// Kept and brought onto the tokens with the rest of the session surface (DG P4) — Plan Y cites it
/// as the phone-mirror reference for the HUD launcher — rather than left as an un-audited idiom.
struct QuickActionsOverlay: View {
    @EnvironmentObject var appState: AppState
    @State private var isExecuting = false

    private var actions: [QuickAction] { Config.quickActions }

    private var isIdle: Bool {
        !appState.isProcessing
        && !appState.isListening
        && !appState.speechService.isSpeaking
        && !appState.cameraService.isCaptureInProgress
        && !isExecuting
    }

    var body: some View {
        if appState.isConnected && isIdle && appState.currentMode == .direct && !actions.isEmpty {
            HStack(spacing: 12) {
                ForEach(actions) { action in
                    if action.type == .toggleRecording {
                        RecordingOverlayButton(
                            action: action,
                            controller: appState.sessionRecorder
                        ) {
                            executeAction(action)
                        }
                    } else {
                        Button {
                            executeAction(action)
                        } label: {
                            OverlayButtonLabel(icon: action.icon, label: action.label)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(action.label)
                        .accessibilityHint("Double-tap to execute")
                    }
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        }
    }

    private func executeAction(_ action: QuickAction) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isExecuting = true
        Task {
            defer { isExecuting = false }
            await appState.executeQuickAction(action)
        }
    }
}

/// Shared circular icon + caption used by every overlay button.
private struct OverlayButtonLabel: View {
    let icon: String
    let label: String
    var iconColor: Color = OGTheme.onMedia

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // A fingertip floor, not a type-relative one — see `OGMetrics`.
                Color.clear
                    .frame(width: OGMetrics.minTouchTarget,
                           height: OGMetrics.minTouchTarget)
                    .glassEffect(in: .circle)

                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(iconColor)
            }

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
                .lineLimit(1)
        }
    }
}

/// Record-meeting overlay button — observes the controller so the icon flips to a red stop
/// while a preserved recording is running.
private struct RecordingOverlayButton: View {
    let action: QuickAction
    @ObservedObject var controller: SessionRecorderController
    let execute: () -> Void

    var body: some View {
        Button(action: execute) {
            OverlayButtonLabel(
                icon: controller.isRecording ? "stop.circle.fill" : action.icon,
                label: controller.isRecording ? "Recording" : action.label,
                iconColor: controller.isRecording ? OGTheme.mediaErrorLabel : OGTheme.onMedia
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record meeting")
        .accessibilityValue(controller.isRecording ? "Recording" : "Stopped")
        .accessibilityHint("Double-tap to start or stop recording.")
    }
}
