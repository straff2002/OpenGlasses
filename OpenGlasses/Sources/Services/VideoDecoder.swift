import CoreMedia
import UIKit
import VideoToolbox

/// Errors from the hardware video decoder.
enum VideoDecoderError: Error {
    case invalidFormat
    case configurationError(OSStatus)
    case decodingFailed(OSStatus)
}

/// Plan EO P1 — what to do when a decode fails (pure, so the rule is testable without
/// VideoToolbox).
///
/// Two statuses mean the session itself is gone rather than the frame being bad:
/// `kVTInvalidSessionErr` (-12903), which is what backgrounding produces when iOS reclaims the
/// shared hardware decode service, and `kVTVideoDecoderMalfunctionErr`. Both are recoverable by
/// building a new session for the same format and trying the frame once more. Anything else is
/// counted, and a decoder that has failed three times in a row is not going to be argued out of
/// it — invalidate, so the next frame starts from a fresh session.
enum DecoderRecoveryPolicy {

    enum Action: Equatable {
        /// Invalidate, recreate for the same format description, retry this frame once.
        case rebuildAndRetry
        /// Count the failure and move on; the next frame gets the same session.
        case countFailure
        /// Invalidate and give up on this frame. The next one builds fresh.
        case invalidate
    }

    /// Consecutive failures that exhaust the session's credit.
    static let failureLimit = 3

    /// `consecutiveFailures` is the count *before* this failure, so the third one in a row
    /// arrives here as 2 and invalidates.
    static func action(status: OSStatus, consecutiveFailures: Int) -> Action {
        if consecutiveFailures + 1 >= failureLimit { return .invalidate }
        if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
            return .rebuildAndRetry
        }
        return .countFailure
    }
}

/// Decodes compressed video frames (H.264/HEVC) into raw pixel buffers
/// using VTDecompressionSession. Used for background frame processing
/// where VideoToolbox GPU rendering is unavailable but decompression still works.
///
/// Adapted from VisionClaw's VideoDecoder (MIT License).
///
/// Plan EO P1 hardened it for the path it now actually serves — the glasses stream, decoded on
/// the phone, including with the screen locked:
/// - the session is asked for **software** decode first, because hardware decode runs in a shared
///   out-of-process service iOS tears down on backgrounding while a software decoder stays
///   in-process;
/// - a session that dies is rebuilt and the frame retried, rather than the decoder dying with it;
/// - after a (re)creation, samples are withheld until the first keyframe and the last good
///   picture is what the app sees, so no half-referenced frame reaches a model, a recording or
///   the lens.
///
/// Not thread-safe by itself: one instance is driven from one thread at a time (the SDK's frame
/// listener, serialised by `GlassesFramePipeline`).
final class VideoDecoder {

    struct DecodedFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let duration: CMTime
    }

    private var decompressionSession: VTDecompressionSession?
    private var currentFormatDescription: CMFormatDescription?
    private var onFrameDecoded: ((DecodedFrame) -> Void)?

    /// Whether the last created session took the software specification. Reported once per
    /// creation, so a device that quietly refuses software decode is a fact in the log rather
    /// than a theory about the lock screen.
    private(set) var isSoftwareDecoder = false

    /// Consecutive decode failures of any status, reset by any success.
    private var consecutiveFailures = 0

    /// Withholds samples until the first keyframe after every (re)creation.
    private var keyframeHold = KeyframeHold()

    /// The most recent successfully decoded picture — what the app is shown while the hold is on.
    private(set) var lastGoodImage: UIImage?

    /// The pixel buffer the output callback most recently delivered, consumed by `image(for:)`
    /// on the same thread that called it (VideoToolbox's callback has already fired by the time
    /// `VTDecompressionSessionWaitForAsynchronousFrames` returns).
    private var pendingPixelBuffer: CVPixelBuffer?

    init() {}

    deinit {
        invalidateSession()
    }

    func setFrameCallback(_ callback: @escaping (DecodedFrame) -> Void) {
        onFrameDecoded = callback
    }

    // MARK: - The picture path

    /// Decode one compressed sample and return the picture the app should show.
    ///
    /// Returns the freshly decoded frame when there is one, the last good frame while the
    /// decoder is holding for a keyframe (nil if there has not been one yet), and nil when the
    /// decode fails outright. `producedFreshPicture` says which of those happened, because the
    /// liveness clocks must not be refreshed by a held frame.
    func image(for sampleBuffer: CMSampleBuffer) -> (image: UIImage?, producedFreshPicture: Bool) {
        do {
            try decode(sampleBuffer)
        } catch {
            return (lastGoodImage, false)
        }

        guard let pixelBuffer = pendingPixelBuffer else {
            // Held for a keyframe, or the decoder accepted the frame and produced nothing.
            return (lastGoodImage, false)
        }
        pendingPixelBuffer = nil

        guard let image = makeImage(from: pixelBuffer) else {
            return (lastGoodImage, false)
        }
        lastGoodImage = image
        return (image, true)
    }

    /// Deliberately **not** Core Image. A `CIContext` renders through Metal, and iOS denies GPU
    /// access to a backgrounded app ("GPU access is denied while the app is in the background") —
    /// so with the screen locked every decode would succeed and every `createCGImage` return nil.
    /// The app would see only the held last-good frame and the stall detector would rebuild, every
    /// 1.5 s, a decoder that is not broken. Decoding with the screen locked is the whole reason
    /// this decoder asks for the software specification, so the conversion has to be free of the
    /// same gate.
    ///
    /// The session asks for 32BGRA, IOSurface-backed buffers, so a `CGContext` laid straight over
    /// the locked base address is a pure-CPU conversion. `makeImage()` copies the pixels out,
    /// which is what lets the buffer go back to the decoder's pool the moment we unlock.
    private func makeImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        // BGRA in memory is little-endian 32-bit ARGB, and the alpha byte of a decoded video
        // frame is opaque, so premultiplied is the honest description of it.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(data: baseAddress,
                                      width: CVPixelBufferGetWidth(pixelBuffer),
                                      height: CVPixelBufferGetHeight(pixelBuffer),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmapInfo),
              let cgImage = context.makeImage() else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Decoding

    func decode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoDecoderError.invalidFormat
        }

        if let currentFormat = currentFormatDescription,
           !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: formatDescription) {
            try recreateDecompressionSession(formatDescription: formatDescription)
        } else if decompressionSession == nil {
            try createDecompressionSession(formatDescription: formatDescription)
        }

        // A session that has just been built cannot start mid-GOP.
        guard keyframeHold.admits(keyframe: Self.isKeyframe(sampleBuffer)) else { return }

        do {
            try submit(sampleBuffer)
            consecutiveFailures = 0
        } catch VideoDecoderError.decodingFailed(let status) {
            switch DecoderRecoveryPolicy.action(status: status,
                                                consecutiveFailures: consecutiveFailures) {
            case .rebuildAndRetry:
                consecutiveFailures += 1
                PrivacyLog.camera(.decoder, .rebuilt, count: consecutiveFailures,
                                  error: Self.summary(for: status))
                try recreateDecompressionSession(formatDescription: formatDescription)
                // The fresh session is holding again, so the retry only lands if this frame is
                // itself a keyframe — which is exactly the frame that may safely start a session.
                guard keyframeHold.admits(keyframe: Self.isKeyframe(sampleBuffer)) else { return }
                try submit(sampleBuffer)
                consecutiveFailures = 0
            case .countFailure:
                consecutiveFailures += 1
                throw VideoDecoderError.decodingFailed(status)
            case .invalidate:
                consecutiveFailures = 0
                invalidateSession()
                throw VideoDecoderError.decodingFailed(status)
            }
        }
    }

    private func submit(_ sampleBuffer: CMSampleBuffer) throws {
        guard let session = decompressionSession else {
            throw VideoDecoderError.invalidFormat
        }

        var flagOut = VTDecodeInfoFlags(rawValue: 0)
        let result = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._1xRealTimePlayback],
            frameRefcon: nil,
            infoFlagsOut: &flagOut
        )

        guard result == noErr else {
            throw VideoDecoderError.decodingFailed(result)
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// The OSStatus itself is the diagnostic here — a number cannot carry content, and P2 reads
    /// the -12903s off this line.
    static func summary(for status: OSStatus) -> SafeErrorSummary {
        SafeErrorSummary(category: .unknown, detail: PrivacyToken("VideoToolbox"), code: Int(status))
    }

    /// A sample is a keyframe unless its attachments say `NotSync`. The attachment is absent on
    /// most sync samples, so absence has to read as "yes".
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        guard let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool else { return true }
        return !notSync
    }

    // MARK: - Session lifecycle

    func invalidateSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
            currentFormatDescription = nil
        }
        keyframeHold.rearm()
        pendingPixelBuffer = nil
    }

    /// Throw the session away without losing the last good picture — the stall detector's
    /// `decodeStalled` response. The next frame rebuilds, and holds until a keyframe.
    func rebuild() {
        invalidateSession()
        consecutiveFailures = 0
        PrivacyLog.camera(.decoder, .rebuilt)
    }

    private func recreateDecompressionSession(formatDescription: CMFormatDescription) throws {
        invalidateSession()
        try createDecompressionSession(formatDescription: formatDescription)
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) throws {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = { refcon, _, status, _, imageBuffer, presentationTimeStamp, duration in
            guard status == noErr, let imageBuffer, let refcon else { return }

            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
            let frame = DecodedFrame(
                pixelBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration
            )
            decoder.pendingPixelBuffer = imageBuffer
            decoder.onFrameDecoded?(frame)
        }
        outputCallback.decompressionOutputRefCon = Unmanaged.passUnretained(self).toOpaque()

        // Software first. Hardware decode runs in a shared out-of-process service that iOS tears
        // down when the app is backgrounded; a software decoder lives in this process and keeps
        // producing pictures with the screen locked, which is a product path here.
        let softwareSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false
        ]

        var session: VTDecompressionSession?
        var status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: softwareSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        var software = true

        if status != noErr || session == nil {
            PrivacyLog.camera(.decoder, .softwareUnavailable, error: Self.summary(for: status))
            software = false
            session = nil
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: &outputCallback,
                decompressionSessionOut: &session
            )
        }

        guard let session, status == noErr else {
            throw VideoDecoderError.configurationError(status)
        }

        decompressionSession = session
        currentFormatDescription = formatDescription
        isSoftwareDecoder = software
        keyframeHold.rearm()

        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let subTypeStr = String(format: "%c%c%c%c",
                                (subType >> 24) & 0xFF,
                                (subType >> 16) & 0xFF,
                                (subType >> 8) & 0xFF,
                                subType & 0xFF)
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        PrivacyLog.camera(.decoder, .configured, state: PrivacyToken(software ? "software" : "hardware"),
                          detail: PrivacyToken(subTypeStr),
                          width: Int(dimensions.width), height: Int(dimensions.height))
    }
}
