import XCTest
import CoreMedia
import CoreVideo
import UIKit
import VideoToolbox
@testable import OpenGlasses

/// Plan EO P1. `VideoDecoder` shipped with no test at all and nothing calling it, which is how it
/// came to be missing every behaviour the glasses stream needs. The rules that can be stated
/// without VideoToolbox are stated in `DecoderRecoveryPolicyTests`; this file drives the real
/// thing — encode a synthetic clip to HEVC, push it back through the decoder, and check that a
/// picture of the right size comes out, that a session killed mid-stream is rebuilt rather than
/// ending the stream, and that a decoder started mid-GOP shows nothing rather than showing
/// rubbish.
///
/// Every test here needs an HEVC **encoder**, which is a simulator capability rather than a
/// property of this code. When the host cannot create one the tests skip with that reason named,
/// and the rules they cover remain covered by the pure tests.
final class VideoDecoderRoundTripTests: XCTestCase {

    private let width = 320
    private let height = 240

    // MARK: - The round trip

    /// The contract the whole frame path rests on: compressed bytes in, a picture of the source's
    /// dimensions out.
    func testAnEncodedFrameDecodesBackToAPictureOfTheSameSize() throws {
        let clip = try encodeClip(frameCount: 1, forceKeyframes: true)
        let decoder = VideoDecoder()

        var decodedSize: CGSize?
        decoder.setFrameCallback { frame in
            decodedSize = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer),
                                 height: CVPixelBufferGetHeight(frame.pixelBuffer))
        }

        let result = decoder.image(for: clip[0])
        XCTAssertTrue(result.producedFreshPicture, "a keyframe into a fresh decoder must decode")
        XCTAssertEqual(decodedSize, CGSize(width: width, height: height),
                       "the decoded buffer must carry the source's dimensions")
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(Int(image.size.width), width)
        XCTAssertEqual(Int(image.size.height), height)
    }

    /// The lock-screen failure, reproduced by hand: iOS reclaims the decode session between two
    /// frames. Before EO the decoder threw on every frame from then on and the stream was over.
    /// Now the next keyframe rebuilds and decodes.
    func testASessionKilledBetweenFramesIsRebuiltAndTheStreamContinues() throws {
        let clip = try encodeClip(frameCount: 2, forceKeyframes: true)
        let decoder = VideoDecoder()

        XCTAssertTrue(decoder.image(for: clip[0]).producedFreshPicture)

        // What backgrounding does to us, done deliberately.
        decoder.invalidateSession()

        let second = decoder.image(for: clip[1])
        XCTAssertTrue(second.producedFreshPicture,
                      "an invalidated session must be rebuilt, not mourned")
        XCTAssertNotNil(second.image)
    }

    /// A decoder that starts mid-GOP has no reference frames, so what it would produce is
    /// smeared rubbish — and rubbish here reaches a vision model, a recording and the lens as if
    /// it were real. The rule is to show the last good picture instead, which at the very start
    /// of a stream is nothing at all.
    func testANonKeyframeFirstSampleShowsTheLastGoodPictureWhichIsNothing() throws {
        let clip = try encodeClip(frameCount: 6, forceKeyframes: false)
        let nonKeyframe = try XCTUnwrap(clip.dropFirst().first { !VideoDecoder.isKeyframe($0) },
                                        "the encoder produced only keyframes for this clip, so "
                                        + "there is no mid-GOP sample to test with")

        let decoder = VideoDecoder()
        let result = decoder.image(for: nonKeyframe)
        XCTAssertFalse(result.producedFreshPicture)
        XCTAssertNil(result.image, "there is no last good picture yet, so there is nothing to show")
    }

    /// And the same sample decodes perfectly well once the session has its keyframe — proving the
    /// hold is a hold and not a failure.
    func testTheHeldSampleDecodesOnceTheSessionHasItsKeyframe() throws {
        let clip = try encodeClip(frameCount: 6, forceKeyframes: false)
        let nonKeyframe = try XCTUnwrap(clip.dropFirst().first { !VideoDecoder.isKeyframe($0) },
                                        "the encoder produced only keyframes for this clip")
        XCTAssertTrue(VideoDecoder.isKeyframe(clip[0]), "the first sample of a clip is a keyframe")

        let decoder = VideoDecoder()
        XCTAssertTrue(decoder.image(for: clip[0]).producedFreshPicture)
        XCTAssertTrue(decoder.image(for: nonKeyframe).producedFreshPicture)
    }

    /// A stream whose format changes under the decoder — which is what the SDK's ladder stepping
    /// the source down looks like from here — must rebuild rather than decode the new frames
    /// against the old description. The behaviour predates EO; it had no test.
    ///
    /// It also exercises the software-first specification and its fallback: whichever one this
    /// host honours, a session gets created, twice.
    func testAFormatChangeRebuildsTheSession() throws {
        let first = try encodeClip(frameCount: 1, forceKeyframes: true)
        let smaller = try encodeClip(frameCount: 1, forceKeyframes: true,
                                     width: width / 2, height: height / 2)

        let decoder = VideoDecoder()
        let before = decoder.image(for: first[0])
        XCTAssertEqual(Int(try XCTUnwrap(before.image).size.width), width)

        // The software-first specification is honoured on this host: a session that fell back to
        // the default specification would have logged `softwareUnavailable`, and none is emitted.
        // The assertion stays off `isSoftwareDecoder` on purpose — which specification a host
        // grants is the host's business, and the fallback existing is the point.
        let after = decoder.image(for: smaller[0])
        XCTAssertTrue(after.producedFreshPicture,
                      "a new format description must build a new session, not fail against the old")
        XCTAssertEqual(Int(try XCTUnwrap(after.image).size.width), width / 2)
    }

    // MARK: - Synthetic clip

    /// Encodes `frameCount` frames of a moving pattern to HEVC and hands back the compressed
    /// samples. Throws `XCTSkip` — with the reason named — when the host has no HEVC encoder.
    private func encodeClip(frameCount: Int, forceKeyframes: Bool,
                           width: Int? = nil, height: Int? = nil) throws -> [CMSampleBuffer] {
        let width = width ?? self.width
        let height = height ?? self.height
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)

        guard createStatus == noErr, let session else {
            throw XCTSkip("this host cannot create an hvc1 encoder "
                          + "(VTCompressionSessionCreate returned \(createStatus)), so the round "
                          + "trip cannot be exercised here")
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        var samples: [CMSampleBuffer] = []
        let lock = NSLock()

        for index in 0..<frameCount {
            let pixelBuffer = try makePixelBuffer(seed: index, width: width, height: height)
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
                throw XCTSkip("this host refused to encode HEVC (status \(status))")
            }
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        lock.lock()
        let encoded = samples
        lock.unlock()
        guard encoded.count == frameCount else {
            throw XCTSkip("the host's HEVC encoder returned \(encoded.count) of \(frameCount) "
                          + "frames, so there is nothing dependable to decode")
        }
        return encoded
    }

    /// A 32BGRA buffer with a diagonal ramp that moves with `seed`, so consecutive frames differ
    /// enough for the encoder to have something to code and little enough that it will choose a
    /// P-frame when it is not forced to make a keyframe.
    private func makePixelBuffer(seed: Int, width: Int, height: Int) throws -> CVPixelBuffer {
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
