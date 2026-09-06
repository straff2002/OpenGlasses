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
    /// Whether the placeholder has been up long enough to earn a second line of advice.
    @State private var showColdStartHint = false
    @State private var previousVideoFrameCallback: ((UIImage) -> Void)?

    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var controlCircle: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var recordGlyph: CGFloat = 32

    var body: some View {
        ZStack {
            OGTheme.media.ignoresSafeArea()

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
            } else if isConnecting {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(OGTheme.onMedia)
                    Text("Connecting to camera…")
                        .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary))
                    // A healthy cold start really does take up to ~20 s, so the spinner alone is
                    // truthful and useless. Field reports of "black screen" are almost always
                    // folded hinges or glasses off the face — both of which cut the camera, and
                    // neither of which a spinner mentions. Held back a few seconds so a quick
                    // connect never flashes advice nobody needed.
                    if showColdStartHint {
                        Text(CameraStreamStatePolicy.coldStartHint)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(
                                OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary)
                            )
                            .padding(.horizontal, 32)
                            .transition(.opacity)
                    }
                }
                .task {
                    // Scoped to this branch, so a stream that drops and reconnects gets a fresh
                    // grace period instead of inheriting an expiry from the previous attempt.
                    showColdStartHint = false
                    try? await Task.sleep(for: .seconds(CameraStreamStatePolicy.coldStartHintDelay))
                    guard !Task.isCancelled else { return }
                    showColdStartHint = true
                }
            } else if let error = streamError {
                VStack(spacing: 12) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.largeTitle)
                        .foregroundStyle(OGTheme.mediaWarnLabel)
                    Text(error)
                        .foregroundStyle(OGTheme.onMedia)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                    Button("Try Again") {
                        startStreamIfNeeded()
                    }
                    .buttonStyle(.ogProminentCompact)
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
                            .foregroundStyle(
                                OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary)
                            )
                            // The surrounding `.padding()` is outside the button's
                            // hit region, so the target has to be claimed here.
                            .frame(minWidth: tapTarget, minHeight: tapTarget)
                            .contentShape(Rectangle())
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
                            .foregroundStyle(OGTheme.onMedia)
                            .frame(width: controlCircle, height: controlCircle)
                            .glassEffect(in: .circle)
                    }
                    .disabled(appState.cameraService.isCaptureInProgress)
                    .accessibilityLabel("Take Photo")

                    // Record video
                    Button {
                        Task { await appState.toggleRecording() }
                    } label: {
                        Image(systemName: appState.videoRecorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: recordGlyph))
                            .foregroundStyle(
                                appState.videoRecorder.isRecording ? OGTheme.mediaErrorLabel : OGTheme.onMedia
                            )
                            .frame(width: controlCircle, height: controlCircle)
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
                                .foregroundStyle(
                                    appState.broadcastService.isBroadcasting ? OGTheme.mediaErrorLabel : OGTheme.onMedia
                                )
                                .frame(width: controlCircle, height: controlCircle)
                                .glassEffect(in: .circle)
                            if appState.broadcastService.isBroadcasting {
                                Text("LIVE")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(OGTheme.onBadge)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(OGTheme.badge))
                                    // Rides the circle's edge, so it stays put as
                                    // the control scales with the text size.
                                    .offset(y: controlCircle / 2 - 8)
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
                                .foregroundStyle(OGTheme.onMedia)
                                .frame(width: controlCircle, height: controlCircle)
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

            // CY: broadcast health while live — state, throughput, achieved frame rate and the
            // frames that never made the wire. A LIVE badge alone cannot tell "streaming fine"
            // from "reconnecting into a hole", and those are the two things worth knowing.
            if appState.broadcastService.isBroadcasting {
                VStack {
                    Spacer()
                    BroadcastHealthBar(service: appState.broadcastService)
                        .padding(.bottom, 110)
                }
            }

            // Recording duration overlay
            if appState.videoRecorder.isRecording {
                VStack {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(OGTheme.error)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(appState.videoRecorder.formattedDuration)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OGTheme.onMedia)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    // The ground here is arbitrary video, not a token — an opaque
                    // fill (rather than a wash) is what keeps the pair measurable,
                    // the same reasoning the caption overlay settled on.
                    .background(Capsule().fill(OGTheme.media))
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
                    ReadingCompanionService.shared.isActive ||
                    // Plan CV, camera ownership: continuous narration holds a claim on the stream.
                    // Closing a preview the wearer opened for ten seconds must not take the camera
                    // from the feature walking them down a corridor.
                    appState.cameraService.hasStreamClaims
                if !shouldKeepStreaming {
                    await appState.cameraService.stopStreaming()
                }
            }
        }
    }

    /// Waiting on a first frame — either our own start, or the backend's reconnect after a
    /// stream we still wanted dropped out.
    private var isConnecting: Bool {
        isStartingStream || appState.cameraService.streamingStatus == .waiting
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

/// Compact broadcast health readout over the live preview (Plan CY). Separate view for the same
/// reason as `PinnedFrameCard` below — `AppState` doesn't forward a nested object's changes, and
/// this one refreshes every second.
private struct BroadcastHealthBar: View {
    @ObservedObject var service: BroadcastService

    var body: some View {
        let health = service.health
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(health.state.isLive ? OGTheme.error : OGTheme.warn)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(health.stateLabel)
                    .font(.caption2.weight(.semibold))
            }
            Text(health.bitrateLabel)
            Text(health.frameRateLabel)
            if health.droppedFrameCount > 0 {
                Text("\(health.droppedFrameCount) dropped")
                    .foregroundStyle(OGTheme.mediaWarnLabel)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Opaque, not a wash — same reasoning as the recording badge above:
        // the ground is arbitrary video, so only a solid fill is measurable.
        .background(Capsule().fill(OGTheme.media))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Broadcast \(health.stateLabel), \(health.bitrateLabel), "
                            + "\(health.frameRateLabel), \(health.droppedFrameCount) frames dropped")
    }
}

/// The pinned frame as a floating card over the live preview (Plan CE). Separate view so the
/// `FramePin` ObservableObject is actually observed — `AppState`'s objectWillChange doesn't
/// forward a nested object's changes.
private struct PinnedFrameCard: View {
    @ObservedObject var pin: FramePin
    let onRelease: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let pinned = pin.pinnedFrame {
            VStack {
                HStack {
                    Button(action: onRelease) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.caption2.weight(.bold))
                                Text("PINNED")
                                    .font(.caption2.weight(.bold))
                                Spacer(minLength: 0)
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(OGTheme.onMedia)
                            Image(uiImage: pinned)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(8)
                        // Opaque fill, not a wash — the "PINNED" text and the frame
                        // below it need a measurable ground, and the pinned still is
                        // arbitrary video rather than a palette token.
                        .background(
                            RoundedRectangle(cornerRadius: 12).fill(OGTheme.media)
                        )
                        // The border reinforces the "PINNED" line beside it rather
                        // than carrying the state on its own.
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.yellow.opacity(0.8), lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pinned frame — the assistant sees this. Tap to release.")
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 60)
            .padding(.leading, 16)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        }
    }
}
