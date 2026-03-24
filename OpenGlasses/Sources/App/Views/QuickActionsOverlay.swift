import SwiftUI
import UIKit

/// Horizontal row of quick action buttons shown below the status ring.
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
                    Button {
                        executeAction(action)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                                    )
                                    .frame(width: 44, height: 44)

                                Image(systemName: action.icon)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(.white)
                            }

                            Text(action.label)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
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
