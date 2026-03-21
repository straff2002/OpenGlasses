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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let frame = currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
                            .background(Circle().fill(.ultraThinMaterial))
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
                            .background(Circle().fill(.ultraThinMaterial))
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
                                .background(Circle().fill(.ultraThinMaterial))
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
                }
                .padding(.bottom, 40)
            }

            // Recording duration overlay
            if appState.videoRecorder.isRecording {
                VStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(appState.videoRecorder.formattedDuration)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(.top, 60)
                    Spacer()
                }
            }
        }
        .onReceive(appState.cameraService.framePublisher.throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)) { image in
            currentFrame = image
        }
        .onAppear {
            startStreamIfNeeded()
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
