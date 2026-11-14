import AVFoundation
import SwiftUI
import Combine

/// Full-screen live camera preview: the glasses' frames, or the phone camera's viewfinder.
/// `LivePreviewPicture` decides which. Glasses frames arrive on `CameraService.onVideoFrame`; the
/// phone's picture is a preview layer on the session the stream uses (`PhoneViewfinder`).
struct LivePreviewView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var broadcastService: BroadcastService
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var adminGate = AdminGate.shared
    /// Plan KH: the preview stays, for looking. Going live does not.
    @AppStorage("hipaaMode") private var medicalCompliance = false

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
    @State private var isChangingBroadcast = false
    @State private var isPreviewVisible = false

    // `AppState` doesn't forward a nested object's changes, so these are received rather than read.
    @State private var blurOn = false
    @State private var confirmingBlurOff = false

    /// Plan LT §1: a screen recording, share or mirror, and the blur relay's latest frame for the
    /// preview to draw in place of raw pixels while one runs with the blur on.
    @ObservedObject private var screenCapture = ScreenCaptureState.shared
    @State private var filteredFrame: UIImage?
    @State private var filteredFrameAt: Date?

    /// The camera permission as last read: it can change while the app is away in Settings.
    @State private var phoneAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var phoneCapture = PhoneCaptureStatus.stopped
    /// The viewfinder has handed the camera over for a still.
    @State private var takingPhonePhoto = false

    @ScaledMetric(relativeTo: .body) private var tapTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .title2) private var controlCircle: CGFloat = 56
    @ScaledMetric(relativeTo: .title) private var recordGlyph: CGFloat = 32

    init(broadcastService: BroadcastService, onOpenSetup: @escaping () -> Void) {
        self.broadcastService = broadcastService
        self.onOpenSetup = onOpenSetup
    }

    var body: some View {
        ZStack {
            OGTheme.media.ignoresSafeArea()

            if case .phone(let position) = picture {
                // Plan LT §1: the viewfinder's frames never pass the blur, so it has nothing to
                // show a captured screen and goes blank.
                if phoneCaptureDisplay == .raw {
                    phoneViewfinder(position)
                } else {
                    capturedScreenNotice
                }
            } else if currentFrame != nil, glassesCaptureDisplay != .raw {
                capturedGlassesPicture
            } else if let frame = currentFrame {
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
                // Only a stream on the glasses camera gets here: off air, with no glasses, the
                // picture is the phone's.
                #if !AVENKIN_PHONE_ONLY
                VStack(spacing: 12) {
                    Image(systemName: "eyeglasses")
                        .font(.largeTitle)
                        .foregroundStyle(OGTheme.onMedia)
                        .accessibilityHidden(true)
                    Text("Streaming from the glasses, and they aren't connected.")
                        .foregroundStyle(OGTheme.onMedia)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .accessibilityElement(children: .combine)
                #endif
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

                if medicalCompliance && !isBroadcasting {
                    mediaCaption(LivePreviewPicture.streamingOffCaption)
                        .padding(.bottom, 12)
                } else if case .phone = picture, phoneViewfinderPhase == .live, phoneCaptureDisplay == .raw {
                    mediaCaption(LivePreviewPicture.phoneCaption(
                        isBroadcasting: isBroadcasting,
                        blurOn: blurOn))
                        .padding(.bottom, 12)
                }

                // The state of the switch is on show whoever set it, and who set it goes with it.
                if !canChangeBlur, let organization = PolicyEnvelope.organizationName {
                    mediaCaption(String(localized: "Set by \(organization)"))
                        .padding(.bottom, 12)
                }

                // CY: broadcast health while live — state, throughput, achieved frame rate and the
                // frames that never made the wire. A LIVE badge alone cannot tell "streaming fine"
                // from "reconnecting into a hole", and those are the two things worth knowing.
                if isBroadcasting || broadcastService.sessionState.isConnecting {
                    BroadcastHealthBar(service: broadcastService)
                        .padding(.bottom, 12)
                }

                actionBar
                    .padding(.horizontal, 16)
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
            if picture == .glasses, currentFrame != nil,
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
            } else if case .phoneCameraNotBlurred(let refusal) = notice, refusal.offersTurningOff {
                // Turning it off is all this does. Going live is a second, separate tap.
                Button("Turn Off Blur", role: .destructive) { appState.setBystanderBlur(false) }
                Button("Not Now", role: .cancel) {}
            } else {
                if case .failed = notice, setupReachable {
                    Button("Open Setup", action: onOpenSetup)
                }
                Button("OK", role: .cancel) {}
            }
        } message: { notice in
            Text(verbatim: notice.message)
        }
        .onChange(of: broadcastService.sessionState) { _, state in
            // Includes failures after going live, such as exhausting reconnect attempts.
            if case .failed(let message) = state {
                goLiveNotice = .failed(message)
            }
        }
        .onReceive(appState.privacyFilter.$isEnabled) { blurOn = $0 }
        // Plan LT §1: the relay's frames are kept only while the preview is drawing them.
        .onReceive(appState.outboundFrames.publisher) { frame in
            guard glassesCaptureDisplay == .filtered else {
                if filteredFrame != nil { filteredFrame = nil; filteredFrameAt = nil }
                return
            }
            filteredFrame = frame
            filteredFrameAt = Date()
        }
        .onChange(of: screenCapture.isCaptured) { _, captured in
            // A capture that starts again starts from blank, not from a frame of the last one.
            if !captured { filteredFrame = nil; filteredFrameAt = nil }
        }
        .onReceive(appState.broadcastService.notices) { goLiveNotice = .streamChanged($0) }
        .bystanderBlurOffConfirmation(isPresented: $confirmingBlurOff, appState: appState)
        .onReceive(phoneCamera.statusPublisher.receive(on: DispatchQueue.main)) { phoneCapture = $0 }
        // Plan KH: the session follows the picture, and starts here rather than in `onAppear` so
        // that closing the preview while iOS is asking cannot leave the camera on behind it.
        .task(id: PictureRequest(picture: picture, access: phoneAccess, takingPhoto: takingPhonePhoto)) {
            await showPicture()
        }
        // Back from Settings with the camera allowed, or taken away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { phoneAccess = AVCaptureDevice.authorizationStatus(for: .video) }
        }
        // A pair that connects while this is open is the picture the wearer came here for, unless
        // a phone stream is on air. That stays on the phone, and starting the glasses can leave the
        // app for Meta AI, which would cost the stream its camera.
        .onChange(of: appState.isConnected) { _, connected in
            if connected { startStreamIfNeeded() }
        }
        .onAppear {
            isPreviewVisible = true
            // Subscribe to camera frames via callback
            let previousCallback = appState.cameraService.onVideoFrame
            previousVideoFrameCallback = previousCallback
            appState.cameraService.onVideoFrame = { image in
                previousCallback?(image)
                Task { @MainActor in
                    currentFrame = image
                }
            }
        }
        .onDisappear {
            isPreviewVisible = false
            // A running stream holds its own claim, so this only stops an idle camera.
            phoneCamera.releasePreview()
            appState.cameraService.onVideoFrame = previousVideoFrameCallback
            Task {
                let shouldKeepStreaming =
                    appState.videoRecorder.isRecording ||
                    broadcastService.isBroadcasting ||
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

    private var isBroadcasting: Bool { broadcastService.isBroadcasting }

    // MARK: - A captured screen (Plan LT §1)

    /// The glasses preview (`OutboundFrameConsumer.livePreview`): its frames also pass the blur
    /// relay, so a captured screen draws those. Reads the filter itself rather than `blurOn`, which
    /// arrives a render late.
    private var glassesCaptureDisplay: PreviewCapturePolicy.Display {
        PreviewCapturePolicy.decide(blurOn: appState.privacyFilter.isEnabled,
                                    isCaptured: screenCapture.isCaptured,
                                    scope: .onDevicePreview, hasFilteredSource: true)
    }

    /// The phone camera's viewfinder (`OutboundFrameConsumer.phoneViewfinder`): no filtered source.
    private var phoneCaptureDisplay: PreviewCapturePolicy.Display {
        PreviewCapturePolicy.decide(blurOn: appState.privacyFilter.isEnabled,
                                    isCaptured: screenCapture.isCaptured,
                                    scope: .onDevicePreview, hasFilteredSource: false)
    }

    /// The relay's latest frame while it is fresh, else the notice — never the raw picture.
    private var capturedGlassesPicture: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let age = filteredFrameAt.map { context.date.timeIntervalSince($0) }
            if PreviewCapturePolicy.resolve(glassesCaptureDisplay, filteredFrameAge: age) == .filtered,
               let filteredFrame {
                Image(uiImage: filteredFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(PreviewCapturePolicy.filteredLine)
            } else {
                capturedScreenNotice
            }
        }
    }

    private var capturedScreenNotice: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.largeTitle)
                .foregroundStyle(OGTheme.onMedia)
                .accessibilityHidden(true)
            Text(verbatim: PreviewCapturePolicy.hiddenLine)
                .foregroundStyle(OGTheme.onMedia)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }
    private var activeSource: BroadcastVideoSource { broadcastService.activeSource }

    private var picture: LivePreviewPicture {
        LivePreviewPicture.decide(.init(isBroadcasting: isBroadcasting,
                                        activeSource: activeSource,
                                        preferredSource: preferredBroadcastSource,
                                        glassesConnected: appState.isConnected))
    }

    private var phoneCamera: PhoneVideoSource { broadcastService.phoneVideoSource }

    private var phoneViewfinderPhase: PhoneViewfinderPhase {
        PhoneViewfinderPhase.decide(access: phoneAccess, capture: phoneCapture)
    }

    /// What `picture` needs running. The phone camera is asked for here and nowhere else: the
    /// wearer opening the preview is the reason. Nothing here touches the Meta permission unless
    /// the picture is the glasses.
    private func showPicture() async {
        guard case .phone(let position) = picture else {
            phoneCamera.releasePreview()
            startStreamIfNeeded()
            return
        }
        // Not drawn from here on, and stale by the time the glasses are back.
        currentFrame = nil
        guard !takingPhonePhoto else { return }
        switch phoneAccess {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .video)
            phoneAccess = AVCaptureDevice.authorizationStatus(for: .video)
        case .authorized:
            phoneCamera.claimPreview(position: position)
        default:
            phoneCamera.releasePreview()
        }
    }

    private struct PictureRequest: Equatable {
        let picture: LivePreviewPicture
        let access: AVAuthorizationStatus
        let takingPhoto: Bool
    }

    @ViewBuilder
    private func phoneViewfinder(_ position: AVCaptureDevice.Position) -> some View {
        let phase = phoneViewfinderPhase
        PhoneViewfinder(session: phoneCamera.sessionForPreview, position: position,
                        isRunning: phoneCapture == .running)
            .ignoresSafeArea()
            .accessibilityLabel("Live view from the phone camera")
            .accessibilityAddTraits(.isImage)
            .accessibilityHidden(phase != .live)

        switch phase {
        case .live, .askingForAccess:
            EmptyView()
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(OGTheme.onMedia)
                Text("Starting the phone camera…")
                    .foregroundStyle(OGTheme.onMedia.opacity(OGTheme.Opacity.onMediaTertiary))
            }
        case .paused:
            phoneCameraMessage(systemImage: "video.slash",
                               text: String(localized: "The phone camera is paused. It comes back when iOS releases it."))
        case .unavailable:
            phoneCameraMessage(systemImage: "video.slash",
                               text: String(localized: "This phone's camera isn't available."))
        case .denied:
            VStack(spacing: 12) {
                phoneCameraMessage(systemImage: "camera.badge.ellipsis",
                                   text: String(localized: "Camera access is off. Allow it for Avenkin in iOS Settings to see the phone camera here."))
                if let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                        .buttonStyle(.ogProminentCompact)
                }
            }
        }
    }

    private func phoneCameraMessage(systemImage: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(OGTheme.mediaWarnLabel)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .foregroundStyle(OGTheme.onMedia)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
    }

    /// A line over arbitrary video. Opaque, not a wash: only a solid fill keeps the pair measurable,
    /// the same reasoning as the recording badge.
    private func mediaCaption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(OGTheme.onMedia)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(OGTheme.media))
            .padding(.horizontal, 16)
    }

    // MARK: - The action bar

    /// One row where it fits. Two where it doesn't, which is the case once the switch-camera menu
    /// joins it on a narrow phone or at a large text size.
    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                photoButton
                #if !AVENKIN_PHONE_ONLY
                recordButton
                #endif
                goLiveButton
                blurButton
                sourceMenu
            }
            VStack(spacing: 12) {
                HStack(spacing: 24) {
                    photoButton
                    #if !AVENKIN_PHONE_ONLY
                    recordButton
                    #endif
                    goLiveButton
                }
                HStack(spacing: 16) {
                    blurButton
                    sourceMenu
                }
            }
        }
    }

    private var photoButton: some View {
        Button {
            takePhoto()
        } label: {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(OGTheme.onMedia)
                .frame(width: controlCircle, height: controlCircle)
                .glassEffect(in: .circle)
        }
        .disabled(!LivePreviewPicture.photoEnabled(
            glassesConnected: appState.isConnected,
            capturing: appState.cameraService.isCaptureInProgress || takingPhonePhoto,
            picture: picture,
            viewfinder: phoneViewfinderPhase,
            isBroadcasting: isBroadcasting))
        .accessibilityLabel("Take Photo")
    }

    /// With no glasses this is `capturePhoto()`'s own phone path, which starts a session of its own,
    /// so the viewfinder gives the camera up first and takes it back after.
    private func takePhoto() {
        Task {
            guard !appState.isConnected else {
                await appState.captureAndSharePhoto()
                return
            }
            takingPhonePhoto = true
            await phoneCamera.releasePreviewAndWait()
            await appState.captureAndSharePhoto(allowingPhoneCamera: true)
            takingPhonePhoto = false
        }
    }

    #if !AVENKIN_PHONE_ONLY
    private var recordButton: some View {
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
        // A recording is frames through the blur relay, and phone frames do not pass through it.
        .accessibilityHint(appState.isConnected ? "" : "Recording needs glasses connected.")
    }
    #endif

    /// Stopping is always on offer: a stream cannot outlive the mode coming on, but this must not
    /// be what stands in its way if it ever did.
    @ViewBuilder
    private var goLiveButton: some View {
        if !medicalCompliance || isBroadcasting { goLiveControl }
    }

    private var goLiveControl: some View {
        Button {
            Task { await goLiveTapped() }
        } label: {
            ZStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(isBroadcasting ? OGTheme.mediaErrorLabel : OGTheme.onMedia)
                    .frame(width: controlCircle, height: controlCircle)
                    .glassEffect(in: .circle)
                if isBroadcasting {
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
        .disabled(isChangingBroadcast)
        .accessibilityLabel(isBroadcasting ? "Stop Broadcasting" : "Go Live")
    }

    private var canChangeBlur: Bool { BystanderBlurControl.isChangeable(in: adminGate.settingsContext) }

    /// Blur Bystander Faces, a tap away from the button it decides. Says on or off in words, and
    /// stays readable when it can't be changed (`SettingsVisibilityPolicy.alwaysShown`).
    private var blurButton: some View {
        Button {
            switch BystanderBlurControl.request(!blurOn, isOn: blurOn, changeable: canChangeBlur,
                                                isLive: appState.isStreamingLive) {
            case .none: break
            case .set(let enabled): appState.setBystanderBlur(enabled)
            case .confirmTurningOff: confirmingBlurOff = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: blurOn ? "face.dashed.fill" : "face.dashed")
                    .font(.title3)
                    .accessibilityHidden(true)
                Text(blurOn ? "Blur On" : "Blur Off")
                    .font(.subheadline.weight(.semibold))
                if !canChangeBlur {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(OGTheme.onMedia)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(minHeight: controlCircle)
            .glassEffect(in: .capsule)
        }
        .disabled(!canChangeBlur)
        .accessibilityLabel("Blur Bystander Faces")
        .accessibilityValue(blurOn ? "On" : "Off")
        .accessibilityHint(canChangeBlur ? "Double-tap to change." : "Can't be changed on this phone.")
    }

    /// BS P3: mid-stream source switch — no RTMP teardown, just re-routes which camera feeds the
    /// encoder (debounced in the service).
    @ViewBuilder
    private var sourceMenu: some View {
        if isBroadcasting {
            Menu {
                ForEach(BroadcastVideoSource.available, id: \.rawValue) { source in
                    Button {
                        switchCamera(to: source)
                    } label: {
                        if activeSource == source {
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

    /// Refused with the blur on, and said so: a menu row that does nothing reads as a broken one.
    private func switchCamera(to source: BroadcastVideoSource) {
        switch BroadcastGoLive.decideSwitch(to: source, faceBlurOn: blurOn) {
        case .switchCamera:
            appState.broadcastService.switchSource(source)
        case .phoneCameraNotBlurred:
            goLiveNotice = .phoneCameraNotBlurred(BystanderBlurControl.refusal(
                route: .midStreamSwitch, changeable: canChangeBlur,
                organization: PolicyEnvelope.organizationName))
        }
    }

    /// `AppState.toggleBroadcast()` reports a missing URL or key as an error, which is right for
    /// Siri. Here the wearer is looking at the button, so they get the way to fix it.
    private func goLiveTapped() async {
        guard !isChangingBroadcast else { return }
        isChangingBroadcast = true
        defer { isChangingBroadcast = false }
        var decision = goLiveDecision()
        // Asked before the stream starts, so the microphone isn't on air behind the iOS prompt.
        if startsOnPhone(decision), AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            phoneAccess = AVCaptureDevice.authorizationStatus(for: .video)
            decision = goLiveDecision()
        }
        switch decision {
        case .toggle(let source):
            await appState.toggleBroadcast(startSource: source) { message in
                if isPreviewVisible {
                    goLiveNotice = .failed(message)
                } else {
                    appState.errorMessage = message
                }
            }
        case .needsSetup(let canOpenSettings):
            goLiveNotice = canOpenSettings ? .setUp : .notSetUp
        case .phoneCameraNotBlurred(let route):
            goLiveNotice = .phoneCameraNotBlurred(BystanderBlurControl.refusal(
                route: route, changeable: canChangeBlur, organization: PolicyEnvelope.organizationName))
        case .phoneCameraDenied:
            goLiveNotice = .phoneCameraDenied
        case .blockedByMedicalCompliance:
            goLiveNotice = .streamChanged(BroadcastGoLive.medicalComplianceMessage)
        }
    }

    private var preferredBroadcastSource: BroadcastVideoSource {
        BroadcastVideoSource.resolved(Config.broadcastDefaultSource)
    }

    private func goLiveDecision() -> BroadcastGoLive.Decision {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        return BroadcastGoLive.decide(.init(
            isBroadcasting: broadcastService.isBroadcasting,
            isConfigured: Config.isBroadcastConfigured,
            preferredSource: preferredBroadcastSource,
            glassesConnected: appState.isConnected,
            faceBlurOn: appState.privacyFilter.isEnabled,
            phoneCameraDenied: camera == .denied || camera == .restricted,
            setupReachable: setupReachable,
            dualCaptureOn: Config.broadcastDualCapture,
            medicalCompliance: Config.hipaaMode))
    }

    private var setupReachable: Bool {
        SettingsVisibilityPolicy.hubCategories(
            simpleMode: Config.simpleModeEnabled, in: AdminGate.shared.settingsContext)
            .contains { $0.id == .capture }
    }

    private func startsOnPhone(_ decision: BroadcastGoLive.Decision) -> Bool {
        guard !broadcastService.isBroadcasting,
              case .toggle(let source) = decision else { return false }
        return (source ?? preferredBroadcastSource).isPhone
    }

    private func startStreamIfNeeded() {
        // The glasses camera is all this starts, and asking for it can leave the app for Meta AI.
        // With no glasses there is nothing to wait for, and with the picture on the phone there is
        // nothing to show.
        guard picture == .glasses, appState.isConnected, !appState.cameraService.isStreaming,
              !isStartingStream else { return }
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
    case phoneCameraNotBlurred(BystanderBlurControl.Refusal)
    case phoneCameraDenied
    case failed(String)
    /// A running stream moved camera, or ended, because of something that changed under it.
    case streamChanged(String)

    var title: String {
        switch self {
        case .setUp, .notSetUp: return String(localized: "Live streaming isn't set up")
        case .phoneCameraNotBlurred: return String(localized: "Can't blur the phone camera")
        case .phoneCameraDenied: return String(localized: "Camera access is off")
        case .failed: return String(localized: "Couldn't broadcast")
        case .streamChanged: return String(localized: "Live stream")
        }
    }

    var message: String {
        switch self {
        case .setUp:
            return String(localized: "In Settings, open Devices & Privacy, then Camera, Recording & Streaming, to find Live Streaming. Add a valid RTMP URL and your platform's stream key, then come back to go live.")
        case .notSetUp:
            return String(localized: "A valid RTMP URL and stream key are needed to go live. Live Streaming settings aren't available on this phone.")
        case .phoneCameraNotBlurred(let refusal):
            return refusal.message
        case .phoneCameraDenied:
            return String(localized: "Allow camera access for Avenkin in iOS Settings to stream from the phone.")
        case .failed(let message), .streamChanged(let message):
            return message
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
