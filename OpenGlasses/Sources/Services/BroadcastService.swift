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
/// Key patterns from SpecBridge analysis:
///   - Encoder priming: feed a CMSampleBuffer before calling publish() to avoid 0x0 metadata
///   - CPU-based pixel buffer conversion (no Metal/GPU) for background safety
@MainActor
class BroadcastService: ObservableObject {
    @Published var isBroadcasting = false
    @Published var broadcastError: String?
    @Published var broadcastDuration: TimeInterval = 0

    private var frameSubscription: AnyCancellable?
    private var durationTimer: Timer?
    private var startTime: Date?

    // BS P2: output geometry from Settings (portrait 720×1280 / landscape 1280×720).
    // Mutated only in startBroadcast (before frames flow), read from the frame queue —
    // same nonisolated(unsafe) discipline as the pool/counters below.
    nonisolated(unsafe) private var outputWidth = 720
    nonisolated(unsafe) private var outputHeight = 1280
    nonisolated(unsafe) private var frameCount: Int = 0
    private let targetFPS: Double = 15

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

    /// Reused pixel-buffer pool so each frame doesn't allocate a fresh ~3.7 MB buffer (~55 MB/s of
    /// churn at 15 fps). Mirrors VideoRecordingService. Frames are pushed serially, matching its
    /// `nonisolated(unsafe)` discipline.
    nonisolated(unsafe) private var pixelBufferPool: CVPixelBufferPool?

    // HaishinKit components
    private var rtmpConnection: RTMPConnection?
    private var rtmpStream: RTMPStream?
    private var mediaMixer: MediaMixer?

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

        // Parse URL: split into connection URL and stream name
        // e.g. rtmp://a.rtmp.youtube.com/live2 + streamKey
        let connectionURL: String
        let streamName: String

        if rtmpURL.hasSuffix("/") {
            connectionURL = String(rtmpURL.dropLast())
            streamName = streamKey
        } else {
            connectionURL = rtmpURL
            streamName = streamKey
        }

        NSLog("[Broadcast] Connecting to %@/%@", connectionURL, String(streamName.prefix(8)) + "...")

        do {
            // Create RTMP connection and stream
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection)

            // Configure video encoding. Bitrate follows the output geometry and the push rate
            // (see `VideoBitratePolicy`), on the `.rtmp` profile — a live stream is bound by the
            // phone's uplink, not by disk, so it takes a lower target and a much lower ceiling
            // than a recording of the same frame.
            let videoBitrate = VideoBitratePolicy.bitrate(
                width: outputWidth,
                height: outputHeight,
                frameRate: targetFPS,
                profile: .rtmp
            )
            NSLog("[Broadcast] Encoding \(outputWidth)x\(outputHeight) @ "
                  + "\(Int(targetFPS.rounded()))fps, \(videoBitrate) bps")
            try await stream.setVideoSettings(VideoCodecSettings(
                videoSize: CGSize(width: outputWidth, height: outputHeight),
                bitRate: videoBitrate,
                profileLevel: kVTProfileLevel_H264_Main_AutoLevel as String,
                maxKeyFrameIntervalDuration: 2
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

            // Connect to RTMP server
            _ = try await connection.connect(connectionURL)
            NSLog("[Broadcast] Connected to RTMP server")

            // Encoder priming: send one blank frame before publish
            // This prevents the 0x0 metadata race condition found in SpecBridge
            if let primingBuffer = Self.createBlankSampleBuffer(width: outputWidth, height: outputHeight) {
                await mixer.append(primingBuffer)
                NSLog("[Broadcast] Encoder primed with blank frame")
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for encoder to process
            }

            // Start publishing
            _ = try await stream.publish(streamName)
            NSLog("[Broadcast] Live! Publishing as '%@'", streamName.prefix(8).description)

        } catch {
            NSLog("[Broadcast] Connection failed: %@", error.localizedDescription)
            broadcastError = error.localizedDescription
            cleanup()
            throw BroadcastError.connectionFailed(error.localizedDescription)
        }

        isBroadcasting = true
        broadcastError = nil
        frameCount = 0
        startTime = Date()

        // Start duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let start = self?.startTime {
                    self?.broadcastDuration = Date().timeIntervalSince(start)
                }
            }
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
        NSLog("[Broadcast] Stopped after %d frames", frameCount)
    }

    /// Formatted broadcast duration string (MM:SS)
    var formattedDuration: String {
        let minutes = Int(broadcastDuration) / 60
        let seconds = Int(broadcastDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
        guard let sampleBuffer = Self.createSampleBuffer(from: buffer) else { return }

        frameCount += 1

        // Feed to MediaMixer → RTMPStream
        Task { @MainActor [weak self] in
            guard let mixer = self?.mediaMixer else { return }
            await mixer.append(sampleBuffer)
        }
    }

    // MARK: - Helpers

    private static nonisolated func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard let desc = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
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

    private static func createBlankSampleBuffer(width: Int, height: Int) -> CMSampleBuffer? {
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

        return createSampleBuffer(from: buffer)
    }

    private func cleanup() {
        rtmpStream = nil
        rtmpConnection = nil
        mediaMixer = nil
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
