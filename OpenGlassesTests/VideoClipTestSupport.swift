import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import OpenGlasses

/// Compressed video for tests that drive the real decoder: a short clip encoded on the host, and
/// ways to re-wrap its samples as a stream that is less helpful than VideoToolbox's own.
///
/// The encoder is a capability of the host, not of the code under test, so every entry point
/// throws `XCTSkip` with the reason named when the host cannot oblige.
enum VideoClipTestSupport {

    static let width = 320
    static let height = 240

    /// Encodes `frameCount` frames of a moving pattern and hands back the compressed samples.
    /// With `forceKeyframes` off the encoder is left to choose, which for a real-time session
    /// without reordering means one keyframe and then P-frames.
    static func encodeClip(codec: CMVideoCodecType = kCMVideoCodecType_HEVC,
                           frameCount: Int, forceKeyframes: Bool) throws -> [CMSampleBuffer] {
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)

        guard createStatus == noErr, let session else {
            throw XCTSkip("this host cannot create an encoder for codec \(codec) "
                          + "(VTCompressionSessionCreate returned \(createStatus))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        var samples: [CMSampleBuffer] = []
        let lock = NSLock()

        for index in 0..<frameCount {
            let pixelBuffer = try makePixelBuffer(seed: index)
            let properties: CFDictionary? = forceKeyframes
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                : nil
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
                duration: CMTime(value: 1, timescale: 30),
                frameProperties: properties,
                infoFlagsOut: &flags,
                outputHandler: { status, _, sampleBuffer in
                    guard status == noErr, let sampleBuffer else { return }
                    lock.lock()
                    samples.append(sampleBuffer)
                    lock.unlock()
                })
            guard status == noErr else {
                throw XCTSkip("this host refused to encode codec \(codec) (status \(status))")
            }
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        lock.lock()
        let encoded = samples
        lock.unlock()
        guard encoded.count == frameCount else {
            throw XCTSkip("the host's encoder returned \(encoded.count) of \(frameCount) frames, "
                          + "so there is nothing dependable to decode")
        }
        return encoded
    }

    /// The same compressed bytes, format description and timing in a new sample buffer that
    /// carries **no attachments at all**. This is the stream the field report describes: nothing
    /// on a sample says whether it is a keyframe.
    static func withoutAttachments(_ sampleBuffer: CMSampleBuffer) throws -> CMSampleBuffer {
        let blockBuffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer),
                                        "an encoded sample has a data buffer")
        return try makeSample(like: sampleBuffer, dataBuffer: blockBuffer)
    }

    /// A stripped copy whose `NotSync` attachment is then set to `notSync`, whatever the sample
    /// really is.
    static func marking(_ sampleBuffer: CMSampleBuffer, notSync: Bool) throws -> CMSampleBuffer {
        let copy = try withoutAttachments(sampleBuffer)
        let attachments = try XCTUnwrap(
            CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true),
            "a sample buffer makes its attachments array on request")
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                  to: CFMutableDictionary.self)
        CFDictionarySetValue(
            first,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(notSync ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
        return copy
    }

    /// A stripped copy whose bytes live in three separate pieces of memory, the first break
    /// falling inside the first NAL unit's length prefix. A block buffer is allowed to be
    /// assembled like this, and nothing says the glasses' samples are not.
    static func inPieces(_ sampleBuffer: CMSampleBuffer) throws -> CMSampleBuffer {
        let source = try XCTUnwrap(CMSampleBufferGetDataBuffer(sampleBuffer))
        let bytes = [UInt8](try source.dataBytes())
        try XCTSkipIf(bytes.count < 16, "the sample is too small to cut up")

        var assembled: CMBlockBuffer?
        var status = CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: 0,
                                              flags: 0, blockBufferOut: &assembled)
        let blockBuffer = try XCTUnwrap(assembled, "CMBlockBufferCreateEmpty failed (\(status))")

        var offset = 0
        for end in [2, bytes.count / 2, bytes.count] {
            let length = end - offset
            status = CMBlockBufferAppendMemoryBlock(
                blockBuffer, memoryBlock: nil, length: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag)
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            status = bytes.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset,
                                              blockBuffer: blockBuffer,
                                              offsetIntoDestination: offset, dataLength: length)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            offset = end
        }
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: bytes.count),
                       "the point of this sample is that its bytes are not in one piece")
        return try makeSample(like: sampleBuffer, dataBuffer: blockBuffer)
    }

    // MARK: - Internals

    private static func makeSample(like sampleBuffer: CMSampleBuffer,
                                   dataBuffer: CMBlockBuffer) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sampleBuffer))
        var timing = CMSampleTimingInfo()
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing),
                       noErr)
        var size = CMBlockBufferGetDataLength(dataBuffer)

        var rebuilt: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &rebuilt)
        return try XCTUnwrap(rebuilt, "CMSampleBufferCreateReady failed (\(status))")
    }

    /// A 32BGRA buffer with a diagonal ramp that moves with `seed`, so consecutive frames differ
    /// enough for the encoder to have something to code and little enough that it will choose a
    /// P-frame when it is not forced to make a keyframe.
    private static func makePixelBuffer(seed: Int) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer, "CVPixelBufferCreate failed (\(status))")

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw XCTSkip("no base address on a freshly created pixel buffer")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x + seed * 2) % 256)          // B
                pixels[offset + 1] = UInt8((y + seed * 2) % 256)      // G
                pixels[offset + 2] = UInt8((x + y + seed * 2) % 256)  // R
                pixels[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
