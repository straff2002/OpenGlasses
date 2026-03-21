import SwiftUI

/// Bottom control bar with circular action buttons in a stable 6-slot layout.
/// Button positions never shift — unavailable slots are hidden but reserve space.
/// Layout: [Settings] [Model] — Spacer — [Camera] [Hero] — Spacer — [Preview] [Mode]
struct BottomControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    /// Sheet bindings passed down from MainView
    @Binding var showSettings: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPreview: Bool

    private var isRealtime: Bool { appState.currentMode.isRealtime }
    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }

    private var realtimeSessionActive: Bool {
        isGemini ? session.isActive : (isOpenAI ? openAISession.isActive : false)
    }

    // MARK: - Slot visibility

    private var previewVisible: Bool { appState.isConnected }
    private var modeVisible: Bool {
        switch appState.currentMode {
        case .geminiLive, .openaiRealtime: return true
        case .direct: return Config.isGeminiLiveConfigured
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left group: Settings + Model
            HStack(spacing: 12) {
                CircleButton(icon: "gearshape", size: 40, label: "Settings") {
                    showSettings = true
                }
                CircleButton(icon: "brain", size: 40, label: "Switch Model") {
                    showModelPicker = true
                }
            }
            .frame(maxWidth: .infinity)

            // Center group: Camera + Hero
            HStack(spacing: 12) {
                cameraButton
                heroButton
            }

            // Right group: Preview + Mode (mirrors left group width)
            HStack(spacing: 12) {
                CircleButton(
                    icon: "eye",
                    size: 40,
                    isActive: appState.videoRecorder.isRecording,
                    label: "Live Preview"
                ) {
                    showPreview = true
                }
                .opacity(previewVisible ? 1 : 0)
                .disabled(!previewVisible)
                .accessibilityHidden(!previewVisible)

                modeButton
                    .opacity(modeVisible ? 1 : 0)
                    .disabled(!modeVisible)
                    .accessibilityHidden(!modeVisible)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .mask(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea()
        )
    }

    // MARK: - Slot Builders

    @ViewBuilder
    private var cameraButton: some View {
        if !appState.isConnected {
            CircleButton(
                icon: "camera.fill",
                size: 48,
                label: "Connect Glasses"
            ) {
                Task { await appState.glassesService.connect() }
                appState.errorMessage = "Connecting glasses for camera…"
            }
        } else if isRealtime {
            CircleButton(
                icon: "video.fill",
                size: 48,
                isActive: appState.cameraService.isStreaming,
                isDisabled: !realtimeSessionActive,
                label: appState.cameraService.isStreaming ? "Camera Streaming" : "Start Camera"
            ) {
                if realtimeSessionActive && !appState.cameraService.isStreaming {
                    Task {
                        do {
                            try await appState.cameraService.startStreaming()
                        } catch {
                            appState.errorMessage = "Camera: \(error.localizedDescription)"
                        }
                    }
                }
            }
        } else {
            CircleButton(
                icon: "camera.fill",
                size: 48,
                isActive: appState.cameraService.isCaptureInProgress,
                isDisabled: appState.cameraService.isCaptureInProgress,
                label: "Take Photo"
            ) {
                Task { await appState.captureAndSharePhoto() }
            }
        }
    }

    @ViewBuilder
    private var heroButton: some View {
        if isGemini {
            CircleButton(
                icon: session.isActive ? "stop.fill" : "play.fill",
                size: 56,
                isActive: session.isActive,
                label: session.isActive ? "Stop Gemini Session" : "Start Gemini Session"
            ) {
                Task {
                    if session.isActive {
                        session.stopSession()
                    } else {
                        await session.startSession()
                    }
                }
            }
        } else if isOpenAI {
            CircleButton(
                icon: openAISession.isActive ? "stop.fill" : "play.fill",
                size: 56,
                isActive: openAISession.isActive,
                label: openAISession.isActive ? "Stop OpenAI Session" : "Start OpenAI Session"
            ) {
                Task {
                    if openAISession.isActive {
                        openAISession.stopSession()
                    } else {
                        await openAISession.startSession()
                    }
                }
            }
        } else {
            CircleButton(
                icon: appState.isListening ? "mic.fill" : "mic",
                size: 56,
                isActive: appState.isListening,
                label: appState.isListening ? "Listening" : "Start Listening"
            ) {
                Task {
                    if appState.isListening {
                        // Tap while listening → cancel and return to wake word
                        await appState.returnToWakeWord()
                    } else {
                        // Tap to start → stop wake word first, then start transcription
                        appState.wakeWordService.stopListening()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        await appState.handleWakeWordDetected()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modeButton: some View {
        switch appState.currentMode {
        case .geminiLive:
            CircleButton(icon: "mic.circle", size: 40, label: "Switch to Voice Mode") {
                appState.switchMode(to: .direct)
            }
        case .openaiRealtime:
            CircleButton(icon: "mic.circle", size: 40, label: "Switch to Voice Mode") {
                appState.switchMode(to: .direct)
            }
        case .direct:
            CircleButton(
                icon: "waveform.circle.fill",
                size: 40,
                badge: "G",
                label: "Switch to Gemini Live"
            ) {
                appState.switchMode(to: .geminiLive)
            }
        }
    }
}
