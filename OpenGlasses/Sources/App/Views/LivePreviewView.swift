import AVFoundation
import SwiftUI
import Combine

/// Full-screen live camera preview from the glasses.
/// Subscribes to CameraService.framePublisher for multi-consumer frame delivery.
struct LivePreviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Streaming isn't set up and the wearer asked to go and set it up. The owner of the cover
    /// closes it and opens Settings: neither can happen from in here.
    private let onOpenSetup: () -> Void

    @State private var currentFrame: UIImage?
    @State private var isStartingStream = false
    @State private var streamError: String?
    /// Whether the placeholder has been up long enough to earn a second line of advice.
    @State private var showColdStartHint = false
    @State private var previousVideoFrameCallback: ((UIImage) -> Void)?
    /// What the Go Live button had to say instead of going live.
    @State private var goLiveNotice: GoLiveNotice?

    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var controlCircle: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var recordGlyph: CGFloat = 32

    init(onOpenSetup: @escaping () -> Void) {
        self.onOpenSetup = onOpenSetup
    }

    var body: some View {
        ZStack {
            OGTheme.media.ignoresSafeArea()

            if let frame = currentFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // FD P0: the label is the readiness phase's, so a held picture is announced as
                    // a held picture. A frozen frame read out as "live camera feed from glasses"
                    // is the same untruth the marker below fixes for sighted users, delivered to
                    // the one person who cannot see that nothing is moving.
                    .accessibilityLabel(appState.cameraService.readiness.previewAccessibilityLabel)
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
            } else if let waiting = waitingWithoutAPicture {
                // FD P0: the preview used to have exactly two placeholders — a spinner labelled
                // "Connecting to camera…" and an error — so a stream that was up and paused, or up
                // and delivering nothing decodable, drew a black rectangle and said nothing at all.
                // These phases are not a cold start and must not borrow its copy.
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundStyle(OGTheme.mediaWarnLabel)
                        .accessibilityHidden(true)
                    Text(waiting.headline)
                        .foregroundStyle(OGTheme.onMedia)
                        .multilineTextAlignment(.center)
                    if let hint = waiting.hint {
                        Text(hint)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(
                                OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaSecondary)
                            )
                            .padding(.horizontal, 32)
                    }
                }
                .accessibilityElement(children: .combine)
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
            } else if !appState.isConnected {
                // The phone camera feeds the encoder directly, with nothing to draw here.
                VStack(spacing: 12) {
                    Image(systemName: "iphone")
                        .font(.largeTitle)
                        .foregroundStyle(OGTheme.onMedia)
                        .accessibilityHidden(true)
                    Text(phoneOnlyHeadline)
                        .foregroundStyle(OGTheme.onMedia)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .accessibilityElement(children: .combine)
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
                    .disabled(appState.cameraService.isCaptureInProgress || !appState.isConnected)
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
                    // Stopping a recording never depends on the glasses still being there.
                    .disabled(!appState.isConnected && !appState.videoRecorder.isRecording)
                    .accessibilityLabel(appState.videoRecorder.isRecording ? "Stop Recording" : "Start Recording")

                    // Go Live
                    Button {
                        Task { await goLiveTapped() }
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

            // FD P0 — a held picture, marked as one, for as long as it is held.
            //
            // The preview deliberately keeps showing the last picture it received when the stream
            // pauses or stalls: a screen that goes black tells the wearer less than a frozen one
            // does. What it must never do is let that picture pass for a live view — so the marker
            // is persistent rather than a flash, it says what the picture *is* rather than only
            // that something is wrong, and it sits over the image instead of beside it. The same
            // sentence is the image's accessibility label above.
            if currentFrame != nil,
               let marker = appState.cameraService.readiness.heldPictureMarker {
                VStack {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(OGTheme.mediaWarnLabel)
                            .accessibilityHidden(true)
                        Text(marker)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OGTheme.onMedia)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Opaque, not a wash: the ground is arbitrary video, so only a solid fill
                    // keeps the pair measurable — the same reasoning as the recording badge.
                    .background(Capsule().fill(OGTheme.media))
                    .padding(.top, 110)
                    .padding(.horizontal, 16)
                    // Hidden from VoiceOver because the image's own label already says it: two
                    // elements reading the same sentence is a swipe spent learning nothing.
                    .accessibilityHidden(true)
                    Spacer()
                }
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
        // Plan GB P4: the record button lives in this full-screen cover, so the share sheet for a
        // finished recording has to present from here — VoiceTab's sheet sits underneath the
        // cover and could not come up while it was showing.
        .sheet(item: $appState.pendingShareItem) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
        .alert(goLiveNotice?.title ?? "",
               isPresented: Binding(get: { goLiveNotice != nil },
                                    set: { if !$0 { goLiveNotice = nil } }),
               presenting: goLiveNotice) { notice in
            if case .setUp = notice {
                Button("Open Setup", action: onOpenSetup)
                Button("Not Now", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(verbatim: notice.message)
        }
        // A pair that connects while this is open is the picture the wearer came here for.
        .onChange(of: appState.isConnected) { _, connected in
            if connected { startStreamIfNeeded() }
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
        isStartingStream || appState.cameraService.readiness.phase == .connecting
            || appState.cameraService.readiness.phase == .awaitingFirstFrame
    }

    /// The camera is on and there is nothing to show — paused, sending nothing, or sending
    /// nothing decodable. `nil` for every phase the two branches either side already cover.
    private var waitingWithoutAPicture: (headline: String, hint: String?)? {
        let readiness = appState.cameraService.readiness
        switch readiness.phase {
        case .paused:
            return (readiness.statusPhrase, CameraStreamStatePolicy.pausedNotice)
        case .framesUnavailable, .decodingStalled:
            return (readiness.statusPhrase, readiness.controlHint)
        case .stopped, .stopping, .connecting, .awaitingFirstFrame, .ready:
            return nil
        }
    }

    private var phoneOnlyHeadline: String {
        if appState.broadcastService.isBroadcasting {
            return String(localized: "Streaming from the phone camera. The picture doesn't show here.")
        }
        // Go Live refuses this fallback with the blur on, so it must not be promised.
        if preferredBroadcastSource == .glasses, appState.privacyFilter.isEnabled {
            return String(localized: "No glasses connected.")
        }
        return String(localized: "No glasses connected. Go Live uses the phone camera, and the picture doesn't show here.")
    }

    /// `AppState.toggleBroadcast()` reports a missing URL or key as an error, which is right for
    /// Siri. Here the wearer is looking at the button, so they get the way to fix it.
    private func goLiveTapped() async {
        var decision = goLiveDecision()
        // Asked before the stream starts, so the microphone isn't on air behind the iOS prompt.
        if startsOnPhone(decision), AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            decision = goLiveDecision()
        }
        switch decision {
        case .toggle(let source):
            await appState.toggleBroadcast(startSource: source)
        case .needsSetup(let canOpenSettings):
            goLiveNotice = canOpenSettings ? .setUp : .notSetUp
        case .phoneCameraNotBlurred:
            goLiveNotice = .phoneCameraNotBlurred
        case .phoneCameraDenied:
            goLiveNotice = .phoneCameraDenied
        }
    }

    private var preferredBroadcastSource: BroadcastVideoSource {
        BroadcastVideoSource(rawValue: Config.broadcastDefaultSource) ?? .glasses
    }

    private func goLiveDecision() -> BroadcastGoLive.Decision {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        return BroadcastGoLive.decide(.init(
            isBroadcasting: appState.broadcastService.isBroadcasting,
            isConfigured: Config.isBroadcastConfigured,
            preferredSource: preferredBroadcastSource,
            glassesConnected: appState.isConnected,
            faceBlurOn: appState.privacyFilter.isEnabled,
            phoneCameraDenied: camera == .denied || camera == .restricted,
            setupReachable: SettingsVisibilityPolicy.hubCategories(
                simpleMode: Config.simpleModeEnabled, in: AdminGate.shared.settingsContext)
                .contains { $0.id == .capture }))
    }

    private func startsOnPhone(_ decision: BroadcastGoLive.Decision) -> Bool {
        guard !appState.broadcastService.isBroadcasting,
              case .toggle(let source) = decision else { return false }
        return (source ?? preferredBroadcastSource).isPhone
    }

    private func startStreamIfNeeded() {
        // The glasses camera is all this starts, and asking for it can leave the app for Meta AI.
        // With no glasses there is nothing to wait for.
        guard appState.isConnected, !appState.cameraService.isStreaming else { return }
        streamError = nil
        isStartingStream = true
        Task {
            do {
                try await appState.cameraService.startStreaming()
                isStartingStream = false
            } catch {
                isStartingStream = false
                streamError = String(localized: "Couldn't start the camera. Make sure your glasses are connected and try again.")
            }
        }
    }
}

/// Why the Go Live button did not go live.
private enum GoLiveNotice {
    case setUp
    case notSetUp
    case phoneCameraNotBlurred
    case phoneCameraDenied

    var title: String {
        switch self {
        case .setUp: return String(localized: "Set up live streaming?")
        case .notSetUp: return String(localized: "Live streaming isn't set up")
        case .phoneCameraNotBlurred: return String(localized: "Can't blur the phone camera")
        case .phoneCameraDenied: return String(localized: "Camera access is off")
        }
    }

    var message: String {
        switch self {
        case .setUp:
            return String(localized: "In Settings, open Camera, Recording & Streaming to find Live Streaming. Add your platform and stream key, then come back to go live.")
        case .notSetUp:
            return String(localized: "Its settings aren't available on this phone.")
        case .phoneCameraNotBlurred:
            return String(localized: "With no glasses connected, a stream would use the phone camera, which Blur Bystander Faces doesn't cover. Connect your glasses, or turn the blur off to stream from the phone.")
        case .phoneCameraDenied:
            return String(localized: "Allow camera access for Avenkin in iOS Settings to stream from the phone.")
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
