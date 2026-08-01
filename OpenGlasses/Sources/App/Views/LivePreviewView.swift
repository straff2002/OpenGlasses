import SwiftUI
import Combine

/// Full-screen live camera preview from the glasses.
/// Subscribes to CameraService.framePublisher for multi-consumer frame delivery.
struct LivePreviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var currentFrame: UIImage?
    @State private var isStartingStream = false
    @State private var streamError: String?
    @State private var previousVideoFrameCallback: ((UIImage) -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("Live camera feed from glasses")
                    // Frame pinning (Plan CE): long-press freezes what the model sees.
                    .onLongPressGesture(minimumDuration: 0.4) {
                        if Config.framePinEnabled, !appState.framePin.isPinned {
                            appState.pinCurrentFrame()
                        }
                    }
                    .accessibilityAction(named: "Pin this frame") {
                        appState.pinCurrentFrame()
                    }
            } else if isStartingStream {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Connecting to camera…")
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if let error = streamError {
                VStack(spacing: 12) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    Button("Try Again") {
                        startStreamIfNeeded()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding()
            }

            // Overlay controls
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityLabel("Close Preview")
                    .padding()
                }
                Spacer()

                // Bottom action bar
                HStack(spacing: 24) {
                    // Capture photo
                    Button {
                        Task { await appState.captureAndSharePhoto() }
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .glassEffect(in: .circle)
                    }
                    .disabled(appState.cameraService.isCaptureInProgress)
                    .accessibilityLabel("Take Photo")

                    // Record video
                    Button {
                        Task { await appState.toggleRecording() }
                    } label: {
                        Image(systemName: appState.videoRecorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(appState.videoRecorder.isRecording ? .red : .white)
                            .frame(width: 56, height: 56)
                            .glassEffect(in: .circle)
                    }
                    .accessibilityLabel(appState.videoRecorder.isRecording ? "Stop Recording" : "Start Recording")

                    // Go Live
                    Button {
                        Task { await appState.toggleBroadcast() }
                    } label: {
                        ZStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(appState.broadcastService.isBroadcasting ? .red : .white)
                                .frame(width: 56, height: 56)
                                .glassEffect(in: .circle)
                            if appState.broadcastService.isBroadcasting {
                                Text("LIVE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(.red))
                                    .offset(y: 20)
                            }
                        }
                    }
                    .accessibilityLabel(appState.broadcastService.isBroadcasting ? "Stop Broadcasting" : "Go Live")

                    // BS P3: mid-stream source switch — no RTMP teardown, just re-routes
                    // which camera feeds the encoder (debounced in the service).
                    if appState.broadcastService.isBroadcasting {
                        Menu {
                            ForEach(BroadcastVideoSource.allCases, id: \.rawValue) { source in
                                Button {
                                    appState.broadcastService.switchSource(source)
                                } label: {
                                    if appState.broadcastService.activeSource == source {
                                        Label(source.displayLabel, systemImage: "checkmark")
                                    } else {
                                        Text(source.displayLabel)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .glassEffect(in: .circle)
                        }
                        .accessibilityLabel("Switch Broadcast Camera")
                    }
                }
                .padding(.bottom, 40)
            }

            // Pinned-frame card (Plan CE): what the model sees, floating over the still-live
            // preview — the disagreement between the two IS the feature. Tap to release.
            PinnedFrameCard(pin: appState.framePin) {
                appState.releaseFramePin(trigger: .explicitUnpin)
            }

            // Recording duration overlay
            if appState.videoRecorder.isRecording {
                VStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(appState.videoRecorder.formattedDuration)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 60)
                    .accessibilityLabel("Recording: \(appState.videoRecorder.formattedDuration)")
                    Spacer()
                }
            }
        }
        .onAppear {
            // Subscribe to camera frames via callback
            let previousCallback = appState.cameraService.onVideoFrame
            previousVideoFrameCallback = previousCallback
            appState.cameraService.onVideoFrame = { image in
                previousCallback?(image)
                Task { @MainActor in
                    currentFrame = image
                }
            }
            startStreamIfNeeded()
        }
        .onDisappear {
            appState.cameraService.onVideoFrame = previousVideoFrameCallback
            Task {
                let shouldKeepStreaming =
                    appState.videoRecorder.isRecording ||
                    appState.broadcastService.isBroadcasting ||
                    appState.webRTCStreaming.isStreaming ||
                    appState.geminiLiveSession.isActive ||
                    appState.openAIRealtimeSession.isActive ||
                    ReadingCompanionService.shared.isActive
                if !shouldKeepStreaming {
                    await appState.cameraService.stopStreaming()
                }
            }
        }
    }

    private func startStreamIfNeeded() {
        guard !appState.cameraService.isStreaming else { return }
        streamError = nil
        isStartingStream = true
        Task {
            do {
                try await appState.cameraService.startStreaming()
                isStartingStream = false
            } catch {
                isStartingStream = false
                streamError = "Couldn't start the camera. Make sure your glasses are connected and try again."
            }
        }
    }
}

/// The pinned frame as a floating card over the live preview (Plan CE). Separate view so the
/// `FramePin` ObservableObject is actually observed — `AppState`'s objectWillChange doesn't
/// forward a nested object's changes.
private struct PinnedFrameCard: View {
    @ObservedObject var pin: FramePin
    let onRelease: () -> Void

    var body: some View {
        if let pinned = pin.pinnedFrame {
            VStack {
                HStack {
                    Button(action: onRelease) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("PINNED")
                                    .font(.system(size: 10, weight: .bold))
                                Spacer(minLength: 0)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            Image(uiImage: pinned)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.65)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.yellow.opacity(0.8), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pinned frame — the assistant sees this. Tap to release.")
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 60)
            .padding(.leading, 16)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
