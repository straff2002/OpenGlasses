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
/// Plan HW P0 made that last rule true for a stream that does not label its own keyframes: what a
/// sample is gets read from its bytes (`NALUnitInspector`), once per sample, and the `NotSync`
/// attachment is the fallback rather than the authority.
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

    /// What this stream has shown about its keyframes, for two log lines per stream. It outlives
    /// a decoder rebuild, which happens inside a stream, and starts again in `resetForNewStream()`.
    private var keyframeEvidence = KeyframeEvidence()

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

        // On the CPU, never Core Image: see `PixelBufferImageConverter` for why that matters
        // with the screen locked.
        guard case .image(let image) = PixelBufferImageConverter.convert(pixelBuffer) else {
            return (lastGoodImage, false)
        }
        lastGoodImage = image
        return (image, true)
    }

    // MARK: - Decoding

    func decode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw VideoDecoderError.invalidFormat
        }

        // Read once: both hold gates below and the evidence ask the same question of the same
        // bytes.
        let inspection = Self.inspect(sampleBuffer)
        record(inspection)

        if let currentFormat = currentFormatDescription,
           !CMFormatDescriptionEqual(currentFormat, otherFormatDescription: formatDescription) {
            try recreateDecompressionSession(formatDescription: formatDescription)
        } else if decompressionSession == nil {
            try createDecompressionSession(formatDescription: formatDescription)
        }

        // A session that has just been built cannot start mid-GOP.
        guard holdAdmits(inspection) else { return }

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
                guard holdAdmits(inspection) else { return }
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

    // MARK: - What a sample is

    /// One sample's readings, taken once per `decode()`.
    struct SampleInspection: Equatable {
        /// What the video itself says the sample is.
        let kind: NALUnitInspector.PictureKind
        /// The `NotSync` sample attachment: nil when the attachment array, its first entry or the
        /// key is absent, otherwise what it says.
        let notSync: Bool?
        /// Whether a random-access sample carries its own parameter sets. Not looked for on any
        /// other sample, where it reads false.
        let parameterSetsInBand: Bool

        /// The rule this decoder shipped with: a sample is a keyframe unless its attachments say
        /// `NotSync`, so an absent attachment reads as "yes".
        var attachmentSaysKeyframe: Bool { notSync != true }

        /// The parser's answer where it has one, the attachment's where it does not.
        var isKeyframe: Bool {
            switch kind {
            case .randomAccess: return true
            case .nonRandomAccess, .leadingSkipped, .leadingDecodable: return false
            case .unparseable: return attachmentSaysKeyframe
            }
        }
    }

    /// Whether a decoder may start on this sample.
    ///
    /// The answer comes from the sample's own bytes: the type of its first slice says whether it
    /// is a random-access picture. It used to come from the `NotSync` attachment alone, with an
    /// absent attachment read as "keyframe" because most sync samples carry none. That attachment
    /// is something an encoder's wrapper adds as a courtesy. VideoToolbox's encoder does, the
    /// glasses stream may never, and a stream that never sets it has no non-keyframes as far as
    /// the attachment can tell. So the attachment is consulted only for a sample the parser
    /// cannot read, where its old rule still applies.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        inspect(sampleBuffer).isKeyframe
    }

    /// The `NotSync` attachment as it is, rather than as the old rule read it: nil means the
    /// sample says nothing either way.
    static func notSyncAttachment(_ sampleBuffer: CMSampleBuffer) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return nil
        }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool
    }

    /// The CoreMedia half of the parser: find the codec, the NAL length-prefix size and the
    /// bytes, and hand them to `NALUnitInspector`. Anything missing makes the sample
    /// `.unparseable`; nothing is assumed, least of all a four-byte prefix.
    static func inspect(_ sampleBuffer: CMSampleBuffer) -> SampleInspection {
        let notSync = notSyncAttachment(sampleBuffer)
        let unparseable = SampleInspection(kind: .unparseable, notSync: notSync,
                                           parameterSetsInBand: false)

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let codec = NALUnitInspector.codec(
                forMediaSubType: CMFormatDescriptionGetMediaSubType(formatDescription)),
              let lengthSize = nalLengthSize(of: formatDescription, codec: codec),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return unparseable
        }

        let read = withBytes(of: blockBuffer) { bytes -> SampleInspection in
            let kind = NALUnitInspector.firstSliceKind(bytes, lengthSize: lengthSize, codec: codec)
            var parameterSetsInBand = false
            if case .randomAccess = kind {
                parameterSetsInBand = NALUnitInspector.hasParameterSets(
                    bytes, lengthSize: lengthSize, codec: codec)
            }
            return SampleInspection(kind: kind, notSync: notSync,
                                    parameterSetsInBand: parameterSetsInBand)
        }
        return read ?? unparseable
    }

    /// The size of the length field in front of each NAL unit, from the format description's
    /// decoder configuration. The parameter-set index is ignored when no parameter set is asked
    /// for, so this works for a description that carries none.
    private static func nalLengthSize(of formatDescription: CMFormatDescription,
                                      codec: NALUnitInspector.Codec) -> Int? {
        var headerLength: Int32 = 0
        let status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &headerLength)
        case .h264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: &headerLength)
        }
        guard status == noErr else { return nil }
        return Int(headerLength)
    }

    /// Runs `body` over the block buffer's bytes. A block buffer may be several pieces of memory
    /// chained together, so the bytes are read in place only when they are known to be one
    /// piece, and copied out otherwise. Nil when the bytes cannot be reached at all.
    private static func withBytes<R>(of blockBuffer: CMBlockBuffer,
                                     _ body: (UnsafeRawBufferPointer) -> R) -> R? {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        if CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: length) {
            var pointer: UnsafeMutablePointer<CChar>?
            var lengthAtOffset = 0
            let status = CMBlockBufferGetDataPointer(
                blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: nil, dataPointerOut: &pointer)
            guard status == kCMBlockBufferNoErr, let pointer, lengthAtOffset >= length else {
                return nil
            }
            return body(UnsafeRawBufferPointer(start: pointer, count: length))
        }

        var copy = [UInt8](repeating: 0, count: length)
        let status = copy.withUnsafeMutableBytes { destination -> OSStatus in
            guard let base = destination.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length,
                                              destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return copy.withUnsafeBytes(body)
    }

    // MARK: - The hold and its evidence

    /// Asks the hold, and says so in the log the one time the hold stops believing the parser.
    private func holdAdmits(_ inspection: SampleInspection) -> Bool {
        let trustedParser = keyframeHold.trustsParser
        let admitted = keyframeHold.admits(
            inspection.kind, attachmentSaysKeyframe: inspection.attachmentSaysKeyframe)
        if trustedParser, !keyframeHold.trustsParser {
            PrivacyLog.camera(.decoder, .keyframeHoldAbandoned, count: KeyframeHold.patience)
        }
        return admitted
    }

    /// Feeds the per-stream evidence and writes whatever it settles. Every value is one of a
    /// fixed set of words or a count; nothing of the picture is in them.
    private func record(_ inspection: SampleInspection) {
        let findings = keyframeEvidence.observe(
            inspection.kind, notSync: inspection.notSync,
            parameterSetsInBand: inspection.parameterSetsInBand)
        for finding in findings {
            switch finding {
            case .source(let source, let samples, let notSync):
                let attachment: String
                switch notSync {
                case .none: attachment = "notSyncAbsent"
                case .some(true): attachment = "notSyncSet"
                case .some(false): attachment = "notSyncClear"
                }
                PrivacyLog.camera(.decoder, .keyframeSource, state: PrivacyToken(attachment),
                                  detail: PrivacyToken(source.rawValue), count: samples)
            case .interval(let samples, let pictureName, let parameterSetsInBand):
                PrivacyLog.camera(
                    .decoder, .keyframeInterval,
                    state: PrivacyToken(parameterSetsInBand ? "parameterSetsInBand"
                                                            : "parameterSetsOutOfBand"),
                    detail: PrivacyToken(pictureName), count: samples)
            }
        }
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

    /// The stream this decoder was serving is gone and the next sample belongs to a new one. The
    /// session goes, as it always did here, and the keyframe evidence starts again so the new
    /// stream writes its own two lines. A rebuild inside a stream must not do that, which is why
    /// this is not `invalidateSession()`. The hold's patience is left alone: what it has learnt
    /// about the glasses' encoder does not change because the stream was restarted.
    func resetForNewStream() {
        invalidateSession()
        keyframeEvidence.reset()
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
