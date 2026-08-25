import Foundation
import Combine
import UIKit
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import HaishinKit
import RTMPHaishinKit

/// RTMP live broadcast service using HaishinKit v2.
///
/// Subscribes to the CameraService framePublisher and encodes UIImage frames
/// as H.264 video over RTMP to YouTube, Twitch, Kick, or any custom endpoint.
///
/// Architecture:
///   UIImage → CVPixelBuffer → CMSampleBuffer → MediaMixer → RTMPStream → RTMP server
///
/// Key patterns:
///   - Encoder priming: feed a CMSampleBuffer before calling publish() to avoid 0x0 metadata
///   - CPU-based pixel buffer conversion (no Metal/GPU) for background safety
///
/// CY: the connection is no longer assumed to survive. Connection and stream status are watched
/// for the whole broadcast, a drop re-runs the connect→prime→publish path on capped exponential
/// backoff (`BroadcastReconnectPolicy`), and the encoder's bitrate follows the link rather than
/// the number it was given at start (`AdaptiveBitratePolicy`). Everything about *when* and *how
/// much* lives in those pure types; this file owns the sockets.
@MainActor
class BroadcastService: ObservableObject {
    @Published var isBroadcasting = false
    @Published var broadcastError: String?
    @Published var broadcastDuration: TimeInterval = 0

    /// CY: where the session is — `idle` / `connecting` / `live` / `reconnecting` / `failed`.
    @Published private(set) var sessionState: BroadcastSessionState = .idle

    /// CY: one refreshed-per-second readout for the live UI. A struct rather than six published
    /// properties because every field moves on the same tick.
    @Published private(set) var health = BroadcastHealth()

    private var frameSubscription: AnyCancellable?
    private var durationTimer: Timer?
    private var startTime: Date?

    // BS P2: output geometry from Settings (portrait 720×1280 / landscape 1280×720).
    // Mutated only in startBroadcast (before frames flow), read from the frame queue —
    // same nonisolated(unsafe) discipline as the pool/counters below.
    nonisolated(unsafe) private var outputWidth = 720
    nonisolated(unsafe) private var outputHeight = 1280
    nonisolated(unsafe) private var frameCount: Int = 0

    // CY: encode frame rate from Settings, replacing the hardcoded 15 that drove bitrate
    // derivation, the throttle interval, frame pacing *and* the sample timescale. Same mirror
    // discipline as the geometry above — written on the main actor before frames flow.
    nonisolated(unsafe) private var targetFPS: Double = 30
    nonisolated(unsafe) private var frameTimescale: Int32 = 30

    // BS P2 / Plan CZ: mic audio comes from `CaptureAudioRouter` (the same source the video
    // recorder uses). The router rides the always-on listener's shared tap while it is running and
    // swaps to its own engine when listening is off, so a stream no longer goes video-only because
    // the wearer turned the wake word off mid-session.
    weak var audioProvider: BroadcastAudioProviding?
    nonisolated(unsafe) private var audioClock = BroadcastAudioClock()
    private static let audioConsumerId = "broadcast_audio"

    // BS P3: source switching + dual capture. `activeSource` drives UI; the
    // nonisolated(unsafe) mirrors are what the frame queue reads (MainActor writes them
    // before/between frames; frames are routed serially).
    @Published private(set) var activeSource: BroadcastVideoSource = .glasses
    private var selector = BroadcastSourceSelector(initial: .glasses)
    private let phoneVideoSource = PhoneVideoSource()
    nonisolated(unsafe) private var mainSourceMirror: BroadcastVideoSource = .glasses
    nonisolated(unsafe) private var dualCaptureMirror = false
    nonisolated(unsafe) private var latestSecondaryFrame: UIImage?
    nonisolated(unsafe) private var lastMainPush = Date.distantPast

    /// Reused pixel-buffer pool so each frame doesn't allocate a fresh ~3.7 MB buffer (~110 MB/s of
    /// churn at 30 fps). Mirrors VideoRecordingService. Frames are pushed serially, matching its
    /// `nonisolated(unsafe)` discipline.
    nonisolated(unsafe) private var pixelBufferPool: CVPixelBufferPool?

    // CY: health counters. Unlike the mirrors above these are written *while* frames flow, so they
    // are kept on the main actor and incremented from the same hop that appends to the mixer —
    // never from the frame queue itself.
    private var pushedFrameCount = 0
    private var unsentFrameCount = 0

    // HaishinKit components
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?
    private var mediaMixer: MediaMixer?

    // CY: reconnection + health state.
    private var machine = BroadcastSessionMachine()
    private var reconnectPolicy = BroadcastReconnectPolicy()
    private var frameRateMeter = BroadcastFrameRateMeter()
    private var bitRateController: BroadcastBitRateController?
    private var statusTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    /// True for the whole life of a broadcast; cleared by `stopBroadcast` and by a give-up. Every
    /// reconnect step is guarded on it, so a stop always wins a race with a pending retry.
    private var wantsConnection = false
    private var connectionURL = ""
    private var streamName = ""
    private var currentTargetBitrate = 0
    private var measuredBitrate = 0
    private var droppedFrameBaseline = 0

    /// CY: supplies the outbound pipeline's own dropped-frame count (`OutboundFrameRelay` discards
    /// frames the blur cannot keep up with). Injected by `AppState` rather than reached for, so
    /// the service stays constructible in a test without the vision stack.
    var droppedFrameSource: (@MainActor () -> Int)?

    /// Start broadcasting to the configured RTMP endpoint.
    func startBroadcast(
        rtmpURL: String,
        streamKey: String,
        from publisher: PassthroughSubject<UIImage, Never>
    ) async throws {
        guard !isBroadcasting else { return }
        guard !rtmpURL.isEmpty, !streamKey.isEmpty else {
            broadcastError = "Configure RTMP URL and stream key in Settings"
            throw BroadcastError.notConfigured
        }

        // BS P2/P3: apply configured geometry and starting source.
        let geometry = BroadcastGeometry.outputSize(orientation: Config.broadcastOrientation)
        outputWidth = geometry.width
        outputHeight = geometry.height
        pixelBufferPool = nil   // dims may have changed since the last broadcast
        let startSource = BroadcastVideoSource(rawValue: Config.broadcastDefaultSource) ?? .glasses
        selector = BroadcastSourceSelector(initial: startSource)
        activeSource = startSource
        mainSourceMirror = startSource
        dualCaptureMirror = Config.broadcastDualCapture
        latestSecondaryFrame = nil
        audioClock = BroadcastAudioClock()

        // CY: encode rate from Settings.
        let configuredFPS = Config.broadcastFrameRate
        targetFPS = Double(configuredFPS)
        frameTimescale = Int32(configuredFPS)

        // Parse URL: split into connection URL and stream name
        // e.g. rtmp://a.rtmp.youtube.com/live2 + streamKey
        if rtmpURL.hasSuffix("/") {
            connectionURL = String(rtmpURL.dropLast())
        } else {
            connectionURL = rtmpURL
        }
        streamName = streamKey

        NSLog("[Broadcast] Connecting to %@/%@", connectionURL, String(streamName.prefix(8)) + "...")

        // CY: a broadcast that has begun wants a connection until the wearer says otherwise.
        wantsConnection = true
        reconnectPolicy.reset()
        frameRateMeter.reset()
        machine = BroadcastSessionMachine()
        machine.apply(.start)
        publishHealth()

        do {
            try await connectAndPublish()
        } catch {
            NSLog("[Broadcast] Connection failed: %@", error.localizedDescription)
            // The *first* connect still fails loudly rather than retrying: nothing is live yet,
            // the wearer is looking at the button they just pressed, and a wrong URL or key would
            // otherwise spend five minutes in a backoff loop before saying so.
            wantsConnection = false
            machine.apply(.fail(error.localizedDescription))
            broadcastError = error.localizedDescription
            cleanup()
            publishHealth()
            throw BroadcastError.connectionFailed(error.localizedDescription)
        }

        isBroadcasting = true
        broadcastError = nil
        frameCount = 0
        pushedFrameCount = 0
        unsentFrameCount = 0
        droppedFrameBaseline = droppedFrameSource?() ?? 0
        startTime = Date()
        markLive()

        // Health/duration tick.
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Subscribe to glasses frames (always — they're the main or the dual inset).
        let interval = 1.0 / targetFPS
        frameSubscription = publisher
            .throttle(for: .seconds(interval), scheduler: DispatchQueue.global(qos: .userInitiated), latest: true)
            .sink { [weak self] image in
                self?.handleFrame(image, from: .glasses)
            }

        // BS P3: phone camera runs when it's the active source or dual capture wants it.
        startPhoneSourceIfNeeded()

        // BS P2 / Plan CZ: attach mic audio. Registering with the router is also what tells it a
        // capture is live, so it brings up whichever source is available.
        if let provider = audioProvider {
            provider.addAudioBufferConsumer(id: Self.audioConsumerId) { [weak self] buffer in
                self?.appendAudio(buffer)
            }
            NSLog("[Broadcast] Mic audio attached")
        } else {
            NSLog("[Broadcast] No audio provider — stream is video-only")
        }
    }

    // MARK: - Connect / reconnect

    /// One connect → configure → prime → publish cycle.
    ///
    /// CY: the initial go-live and every reconnect attempt run *this* method, which is what stops
    /// the reconnect path from quietly diverging from the path that is known to work — including
    /// the encoder priming, which a reconnect needs for exactly the same reason the first connect
    /// does (a republish without it lands 0x0 metadata on the ingest).
    private func connectAndPublish() async throws {
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)

        // Configure video encoding. Bitrate follows the output geometry and the push rate
        // (see `VideoBitratePolicy`), on the `.rtmp` profile — a live stream is bound by the
        // phone's uplink, not by disk, so it takes a lower target and a much lower ceiling
        // than a recording of the same frame. CY: Settings may override it, and whatever comes
        // out is the *ceiling* adaptation works below.
        let ceiling = VideoBitratePolicy.bitrate(
            width: outputWidth,
            height: outputHeight,
            frameRate: targetFPS,
            profile: .rtmp,
            override: Config.broadcastBitrateOverride
        )
        let keyframeSeconds = Config.broadcastKeyframeIntervalSeconds
        NSLog("[Broadcast] Encoding \(outputWidth)x\(outputHeight) @ "
              + "\(Int(targetFPS.rounded()))fps, \(ceiling) bps, keyframe \(keyframeSeconds)s")
        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: outputWidth, height: outputHeight),
            bitRate: ceiling,
            profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String,
            maxKeyFrameIntervalDuration: Int32(keyframeSeconds),
            expectedFrameRate: targetFPS
        ))

        // CY: audio was shipping on the encoder defaults (64 kbps AAC), which is audibly thin for
        // anything but speech in a quiet room. State it explicitly instead.
        try await stream.setAudioSettings(AudioCodecSettings(
            bitRate: Config.broadcastAudioBitrate
        ))

        // Create MediaMixer and wire it to the stream
        let mixer = MediaMixer()
        await mixer.addOutput(stream)
        await mixer.setVideoMixerSettings(VideoMixerSettings(
            mode: .offscreen,
            isMuted: false
        ))

        self.rtmpConnection = connection
        self.rtmpStream = stream
        self.mediaMixer = mixer
        self.currentTargetBitrate = ceiling
        self.measuredBitrate = 0

        // Connect to RTMP server
        _ = try await connection.connect(connectionURL)
        NSLog("[Broadcast] Connected to RTMP server")

        // Encoder priming: send one blank frame before publish. This prevents a 0x0-metadata race
        // where the ingest sees the stream before it sees a frame size.
        if let primingBuffer = Self.createBlankSampleBuffer(width: outputWidth,
                                                           height: outputHeight,
                                                           timescale: frameTimescale) {
            await mixer.append(primingBuffer)
            NSLog("[Broadcast] Encoder primed with blank frame")
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for encoder to process
        }

        // Start publishing
        _ = try await stream.publish(streamName)
        NSLog("[Broadcast] Live! Publishing as '%@'", streamName.prefix(8).description)

        // CY: bitrate control. The transport reports outbound throughput and queue depth roughly
        // once a second; the strategy turns that into a `BroadcastPressureSample` and applies
        // whatever the pure policy decides. Installed after publish so it never sees the
        // handshake's traffic as a stream measurement.
        let controller = BroadcastBitRateController(
            ceiling: ceiling,
            floor: VideoBitratePolicy.Profile.rtmp.minimum
        ) { [weak self] target, measured in
            Task { @MainActor in self?.recordBitrate(target: target, measured: measured) }
        }
        await stream.setBitRateStrategy(controller)
        bitRateController = controller

        observeStatus(connection: connection, stream: stream)
    }

    /// Watch both status streams for the life of this connection.
    ///
    /// Both are watched because they report different halves of the same failure: the connection
    /// stream sees the socket go away, the stream sees the publish stop being accepted, and which
    /// one arrives depends on how the link died. Duplicates are expected and harmless — the
    /// session machine rejects a second `.dropped` from `reconnecting`.
    private func observeStatus(connection: RTMPConnection, stream: RTMPStream) {
        cancelStatusObservation()
        statusTasks = [
            Task { @MainActor [weak self] in
                let statuses = await connection.status
                for await status in statuses {
                    guard !Task.isCancelled else { return }
                    self?.handleConnectionStatus(status)
                }
            },
            Task { @MainActor [weak self] in
                let statuses = await stream.status
                for await status in statuses {
                    guard !Task.isCancelled else { return }
                    self?.handleStreamStatus(status)
                }
            }
        ]
    }

    private func cancelStatusObservation() {
        // The SDK never finishes these continuations on close, so a `for await` over them would
        // outlive the connection it belongs to. Cancelling is the only way out.
        statusTasks.forEach { $0.cancel() }
        statusTasks.removeAll()
    }

    private func handleConnectionStatus(_ status: RTMPStatus) {
        guard let code = RTMPConnection.Code(rawValue: status.code) else { return }
        switch code {
        case .connectRejected, .connectInvalidApp, .callProhibited, .callBadVersion:
            // The server understood us and said no. Retrying a wrong stream key or a disabled
            // ingest just burns five minutes before reporting the same thing.
            fail(reason: status.description.isEmpty ? code.rawValue : status.description)
        case .connectClosed, .connectFailed, .connectAppshutdown,
             .connectIdleTimeOut, .connectNetworkChange, .callFailed:
            handleConnectionLoss(reason: code.rawValue)
        case .connectSuccess:
            break
        }
    }

    private func handleStreamStatus(_ status: RTMPStatus) {
        guard let code = RTMPStream.Code(rawValue: status.code) else { return }
        switch code {
        case .publishStart:
            markLive()
        case .publishBadName:
            // The stream name is already publishing elsewhere — a retry loop would fight it.
            fail(reason: "That stream key is already in use.")
        case .connectClosed, .connectFailed, .failed, .publishIdle:
            // `unpublishSuccess` is deliberately absent: it is the acknowledgement of *our own*
            // unpublish, so treating it as a loss would start a reconnect at every teardown.
            handleConnectionLoss(reason: code.rawValue)
        default:
            break
        }
    }

    /// The stream is publishing.
    private func markLive() {
        reconnectPolicy.recordLive(at: Date())
        if machine.apply(.connected) {
            broadcastError = nil
            publishHealth()
        }
    }

    /// A live connection died. Tear down only the connection objects — the frame subscription,
    /// the phone source and the mic tap all stay attached, so a reconnect resumes the same
    /// broadcast rather than starting a new one.
    private func handleConnectionLoss(reason: String) {
        guard wantsConnection, isBroadcasting else { return }
        // A drop is reported by both status streams; only the first one starts a reconnect.
        guard machine.apply(.dropped) else { return }

        NSLog("[Broadcast] Connection lost (%@) — reconnecting", reason)
        cancelStatusObservation()
        teardownConnectionObjects()

        switch reconnectPolicy.connectionLost(now: Date()) {
        case .giveUp:
            fail(reason: "Lost connection to the streaming server.")
        case .retry(let attempt, let delay):
            machine.apply(.retry(attempt: attempt))
            publishHealth()
            NSLog("[Broadcast] Reconnect #%d in %.0fs", attempt, delay)
            scheduleReconnect(after: delay)
        }
    }

    private func scheduleReconnect(after delay: TimeInterval) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.attemptReconnect()
        }
    }

    private func attemptReconnect() async {
        guard wantsConnection, isBroadcasting else { return }
        do {
            try await connectAndPublish()
            NSLog("[Broadcast] Reconnected")
            markLive()
        } catch {
            NSLog("[Broadcast] Reconnect attempt failed: %@", error.localizedDescription)
            cancelStatusObservation()
            teardownConnectionObjects()
            switch reconnectPolicy.connectionLost(now: Date()) {
            case .giveUp:
                fail(reason: "Couldn't reconnect to the streaming server.")
            case .retry(let attempt, let delay):
                machine.apply(.retry(attempt: attempt))
                publishHealth()
                scheduleReconnect(after: delay)
            }
        }
    }

    /// Give up on this broadcast: report it, and stop everything the way a manual stop would.
    private func fail(reason: String) {
        guard wantsConnection else { return }
        NSLog("[Broadcast] Failed: %@", reason)
        machine.apply(.fail(reason))
        let failedState = machine.state
        broadcastError = reason

        if isBroadcasting {
            stopBroadcast()
        } else {
            // A rejection can land in the window between `connectAndPublish` returning and
            // `startBroadcast` flipping `isBroadcasting`, where `stopBroadcast` would no-op and
            // leave the connection up. Tear it down directly.
            wantsConnection = false
            reconnectTask?.cancel()
            reconnectTask = nil
            cancelStatusObservation()
            teardownConnectionObjects()
        }

        // `stopBroadcast` settles the machine to `.idle`; the wearer still needs to see why it
        // stopped, so the failed state is what gets published.
        machine = BroadcastSessionMachine(state: failedState)
        publishHealth()
    }

    /// Close and drop the RTMP objects without touching the sources feeding them.
    private func teardownConnectionObjects() {
        let stream = rtmpStream
        let connection = rtmpConnection
        rtmpStream = nil
        rtmpConnection = nil
        mediaMixer = nil
        bitRateController = nil
        Task {
            if let stream { _ = try? await stream.close() }
            if let connection { try? await connection.close() }
        }
    }

    // MARK: - Frame routing

    /// BS P3: route a frame by source — active source pushes (composited with the cached
    /// secondary when dual capture is on), the other source only refreshes the cache.
    private nonisolated func handleFrame(_ image: UIImage, from source: BroadcastVideoSource) {
        if mainSourceMirror == source {
            // Phone frames arrive unthrottled (~30fps) — pace the main push to targetFPS.
            let now = Date()
            guard now.timeIntervalSince(lastMainPush) >= (1.0 / targetFPS) * 0.9 else { return }
            lastMainPush = now
            let inset = dualCaptureMirror ? latestSecondaryFrame : nil
            let frame = inset.map { FrameCompositor.compose(main: image, inset: $0) } ?? image
            pushFrame(frame)
        } else {
            latestSecondaryFrame = image
        }
    }

    /// BS P3: switch the live video source without touching the RTMP connection.
    /// Debounced; returns whether the switch was applied.
    @discardableResult
    func switchSource(_ source: BroadcastVideoSource) -> Bool {
        guard isBroadcasting else { return false }
        guard selector.requestSwitch(to: source, now: Date()) else { return false }
        activeSource = source
        mainSourceMirror = source
        latestSecondaryFrame = nil
        startPhoneSourceIfNeeded()
        NSLog("[Broadcast] Source switched to %@", source.rawValue)
        return true
    }

    private func startPhoneSourceIfNeeded() {
        let phoneWanted = activeSource.isPhone || (dualCaptureMirror && activeSource == .glasses)
        if phoneWanted {
            let position = activeSource.phonePosition ?? .back
            phoneVideoSource.start(position: position) { [weak self] image in
                guard let self else { return }
                let kind: BroadcastVideoSource = position == .front ? .phoneFront : .phoneBack
                self.handleFrame(image, from: kind)
            }
        } else {
            phoneVideoSource.stop()
        }
    }

    /// BS P2: routed mic buffer → the mixer's audio track (PTS from a running
    /// sample-count clock; MediaMixer routes AVAudioPCMBuffer appends to the audio IO).
    private nonisolated func appendAudio(_ buffer: AVAudioPCMBuffer) {
        let sampleTime = audioClock.take(frames: buffer.frameLength)
        let when = AVAudioTime(sampleTime: sampleTime, atRate: buffer.format.sampleRate)
        Task { @MainActor [weak self] in
            guard let self, self.isBroadcasting, let mixer = self.mediaMixer else { return }
            await mixer.append(buffer, when: when)
        }
    }

    /// Stop the broadcast.
    func stopBroadcast() {
        guard isBroadcasting else { return }

        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelStatusObservation()

        frameSubscription?.cancel()
        frameSubscription = nil
        audioProvider?.removeAudioBufferConsumer(id: Self.audioConsumerId)
        phoneVideoSource.stop()
        latestSecondaryFrame = nil
        durationTimer?.invalidate()
        durationTimer = nil
        pixelBufferPool = nil

        Task {
            if let stream = rtmpStream {
                _ = try? await stream.close()
            }
            if let connection = rtmpConnection {
                try? await connection.close()
            }
            cleanup()
        }

        isBroadcasting = false
        broadcastDuration = 0
        startTime = nil
        machine.apply(.stop)
        health = BroadcastHealth(state: machine.state)
        sessionState = machine.state
        NSLog("[Broadcast] Stopped after %d frames", frameCount)
    }

    /// Formatted broadcast duration string (MM:SS)
    var formattedDuration: String {
        let minutes = Int(broadcastDuration) / 60
        let seconds = Int(broadcastDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Health

    /// One-second tick: duration, achieved frame rate, dropped frames.
    private func tick() {
        if let start = startTime {
            broadcastDuration = Date().timeIntervalSince(start)
        }
        frameRateMeter.record(frames: pushedFrameCount, at: Date())
        pushedFrameCount = 0
        publishHealth()
    }

    /// The bitrate controller applied a new target (or just measured the link).
    private func recordBitrate(target: Int, measured: Int) {
        currentTargetBitrate = target
        measuredBitrate = measured
        publishHealth()
    }

    private func publishHealth() {
        let relayDrops = max((droppedFrameSource?() ?? 0) - droppedFrameBaseline, 0)
        health = BroadcastHealth(
            state: machine.state,
            configuredFrameRate: Int(targetFPS.rounded()),
            achievedFrameRate: frameRateMeter.rate(),
            targetBitrate: currentTargetBitrate,
            measuredBitrate: measuredBitrate,
            // Both counts are "a frame that did not reach the wire": one discarded by the privacy
            // relay keeping up, one dropped because there was no connection to push it to.
            droppedFrameCount: relayDrops + unsentFrameCount,
            duration: broadcastDuration
        )
        sessionState = machine.state
    }

    // MARK: - Frame Encoding

    /// Dequeue a pixel buffer from the reused pool, lazily creating the pool on first use.
    private nonisolated func dequeuePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pixelBufferPool == nil {
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
            let bufferAttrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary,
                                    bufferAttrs as CFDictionary, &pool)
            pixelBufferPool = pool
        }
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private nonisolated func pushFrame(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }

        let width = outputWidth
        let height = outputHeight

        // Acquire a pixel buffer from the reused pool instead of allocating a new one per frame.
        guard let buffer = dequeuePixelBuffer(width: width, height: height) else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // BS P2: aspect-fit with black letterbox — stretch-to-fill distorted any source
        // whose aspect didn't match the output (phone landscape into portrait, etc.).
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let fit = BroadcastGeometry.aspectFitRect(
            imageSize: CGSize(width: cgImage.width, height: cgImage.height),
            in: CGSize(width: width, height: height))
        context.draw(cgImage, in: fit)

        // Create CMSampleBuffer
        guard let sampleBuffer = Self.createSampleBuffer(from: buffer, timescale: frameTimescale) else { return }

        frameCount += 1

        // Feed to MediaMixer → RTMPStream
        Task { @MainActor [weak self] in
            guard let self else { return }
            // CY: no mixer means the connection is down (a reconnect is in flight). The frame is
            // gone either way; counting it is what makes the gap visible in the health readout
            // instead of silently shortening the stream.
            guard let mixer = self.mediaMixer else {
                self.unsentFrameCount += 1
                return
            }
            self.pushedFrameCount += 1
            await mixer.append(sampleBuffer)
        }
    }

    // MARK: - Helpers

    private static nonisolated func createSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                                       timescale: Int32) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let desc = formatDescription else { return nil }

        // CY: the duration follows the configured rate. It used to be a literal 1/15 while the
        // pacing was also 15 — the two agreed by coincidence, and the coincidence broke the
        // moment the rate became a setting.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: max(timescale, 1)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    private static func createBlankSampleBuffer(width: Int, height: Int,
                                                timescale: Int32) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard let buffer = pixelBuffer else { return nil }

        // Fill with black
        CVPixelBufferLockBaseAddress(buffer, [])
        if let baseAddr = CVPixelBufferGetBaseAddress(buffer) {
            memset(baseAddr, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        return createSampleBuffer(from: buffer, timescale: timescale)
    }

    private func cleanup() {
        rtmpStream = nil
        rtmpConnection = nil
        mediaMixer = nil
        bitRateController = nil
    }
}

/// CY: bridges the transport's network telemetry into `AdaptiveBitratePolicy` and applies what it
/// decides.
///
/// HaishinKit reports outbound throughput and queue depth on its own ~1 Hz monitor and hands them
/// to whatever bitrate strategy is installed. All this type does is translate — it holds no
/// judgement of its own, so the judgement stays in a struct that can be tested against a table of
/// samples with no socket in sight.
final actor BroadcastBitRateController: StreamBitRateStrategy {

    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate: Int = 0

    private var policy: AdaptiveBitratePolicy
    private let onSample: @Sendable (Int, Int) -> Void

    init(ceiling: Int, floor: Int, onSample: @escaping @Sendable (Int, Int) -> Void) {
        self.mamimumVideoBitRate = ceiling
        self.policy = AdaptiveBitratePolicy(ceiling: ceiling, floor: floor)
        self.onSample = onSample
    }

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .reset:
            // A fresh transport: forget the history and go back to the configured ceiling.
            policy.reset()
            var settings = await stream.videoSettings
            settings.bitRate = mamimumVideoBitRate
            try? await stream.setVideoSettings(settings)
            onSample(mamimumVideoBitRate, 0)
        case .status(let report):
            await apply(report, insufficientBandwidth: false, to: stream)
        case .publishInsufficientBWOccured(let report):
            await apply(report, insufficientBandwidth: true, to: stream)
        }
    }

    private func apply(_ report: NetworkMonitorReport,
                       insufficientBandwidth: Bool,
                       to stream: some StreamConvertible) async {
        var settings = await stream.videoSettings
        let sample = BroadcastPressureSample(
            targetBitrate: settings.bitRate,
            measuredBitrate: report.currentBytesOutPerSecond * 8,
            queuedBytes: report.currentQueueBytesOut,
            insufficientBandwidth: insufficientBandwidth
        )
        switch policy.evaluate(sample) {
        case .hold:
            onSample(settings.bitRate, sample.measuredBitrate)
        case .stepDown(let bitrate), .stepUp(let bitrate):
            settings.bitRate = bitrate
            try? await stream.setVideoSettings(settings)
            NSLog("[Broadcast] Bitrate → %d bps (measured %d bps, queue %d B)",
                  bitrate, sample.measuredBitrate, sample.queuedBytes)
            onSample(bitrate, sample.measuredBitrate)
        }
    }
}

enum BroadcastError: LocalizedError {
    case notConfigured
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Broadcast not configured — set RTMP URL and stream key in Settings"
        case .connectionFailed(let reason): return "Broadcast connection failed: \(reason)"
        }
    }
}


/// BS P2: seam for a mic buffer source. Adopted by `WakeWordService` (the shared tap), by
/// `StandaloneMicTapService`, and by `CaptureAudioRouter`, which is what capture consumers actually
/// talk to (Plan CZ). Kept minimal so tests can inject a fake.
///
/// `@MainActor` because the adopters and the call sites (`startBroadcast`/`stopBroadcast`, and the
/// recorder's equivalents) are main-actor: the consumer *registry* is main-actor state, even though
/// the handlers themselves are `@Sendable` and run on the audio thread.
@MainActor
protocol BroadcastAudioProviding: AnyObject {
    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func removeAudioBufferConsumer(id: String)
}
