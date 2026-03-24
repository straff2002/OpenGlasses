import SwiftUI

/// Quick action buttons arranged in a radial layout around the center of the screen.
/// Only visible when glasses are connected and the app is idle.
struct QuickActionsOverlay: View {
    @EnvironmentObject var appState: AppState

    private var actions: [QuickAction] { QuickAction.defaults }

    private var isIdle: Bool {
        !appState.isProcessing
        && !appState.isListening
        && !appState.speechService.isSpeaking
        && !appState.cameraService.isCaptureInProgress
    }

    var body: some View {
        if appState.isConnected && isIdle && appState.currentMode == .direct {
            RadialLayout(radius: 100) {
                ForEach(actions) { action in
                    VStack(spacing: 4) {
                        CircleButton(
                            icon: action.icon,
                            size: 44,
                            label: action.label
                        ) {
                            executeAction(action)
                        }
                        Text(action.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .animation(.easeInOut(duration: 0.25), value: isIdle)
        }
    }

    private func executeAction(_ action: QuickAction) {
        Task {
            switch action.type {
            case .prompt(let text):
                appState.speechService.startThinkingSound()
                do {
                    let rawResponse = try await appState.llmService.sendMessage(
                        text,
                        locationContext: appState.locationService.locationContext,
                        memoryContext: Config.userMemoryEnabled ? appState.userMemory.systemPromptContext() : nil
                    )
                    appState.lastResponse = rawResponse
                    await appState.speechService.speak(rawResponse)
                } catch {
                    appState.speechService.stopThinkingSound()
                    appState.errorMessage = error.localizedDescription
                }

            case .photo:
                await appState.captureAndAnalyzePhoto()

            case .photoThenPrompt(let prompt):
                await appState.capturePhotoAndSend(prompt: prompt)
            }
        }
    }
}
