import XCTest
import CoreMedia
import UIKit
import VideoToolbox
@testable import OpenGlasses

/// Plan HW P0. `VideoDecoderRoundTripTests` proves the keyframe hold on clips VideoToolbox
/// encoded, and VideoToolbox marks every non-keyframe `NotSync`. The glasses stream is reported
/// not to, and against a stream that says nothing the old rule (no attachment means keyframe)
/// called every sample a keyframe: the hold let the first one through, and a decoder rebuilt
/// with the phone locked started mid-GOP.
///
/// These tests take the same simulator-encoded clips and re-wrap each sample with no attachments
/// at all, which is that stream, and then drive the real decoder with it. They also check the
/// parser against the encoder on every sample of a clip, so its rules are not only as good as the
/// bytes someone wrote out by hand.
///
/// Like the round-trip tests they need an encoder, which the host may not have; they skip with
/// the reason named when it does not.
final class VideoDecoderKeyframeTests: XCTestCase {

    // MARK: - The field failure

    /// A mid-GOP P-frame that carries nothing to say so. The old rule read it as a keyframe and
    /// decoded it into a session with no reference frames.
    func testAPFrameWithNoAttachmentIsNotAKeyframeAndAFreshDecoderShowsNothing() throws {
        let stripped = try VideoClipTestSupport.withoutAttachments(try encodedPFrame())
        XCTAssertNil(CMSampleBufferGetSampleAttachmentsArray(stripped, createIfNecessary: false),
                     "the re-wrapped sample must carry no attachments, or this proves nothing")
        XCTAssertNil(VideoDecoder.notSyncAttachment(stripped))

        XCTAssertFalse(VideoDecoder.isKeyframe(stripped),
                       "the video says this is not a keyframe, whatever the attachments leave out")

        let decoder = VideoDecoder()
        let result = decoder.image(for: stripped)
        XCTAssertFalse(result.producedFreshPicture)
        XCTAssertNil(result.image, "there is no last good picture yet, so there is nothing to show")
    }

    /// The lock-screen case in full, on a stream with no attachments: the decoder is running,
    /// its session is thrown away mid-GOP, and the frames that follow must be withheld — the
    /// last good picture stays up — until a keyframe arrives.
    func testADecoderRebuiltMidStreamWaitsForTheNextKeyframe() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 6, forceKeyframes: false)
            .map(VideoClipTestSupport.withoutAttachments)
        let pFrames = clip.filter { !VideoDecoder.isKeyframe($0) }
        XCTAssertGreaterThanOrEqual(pFrames.count, 3, "the encoder produced too few P-frames "
                                    + "for this clip to have a middle")
        XCTAssertTrue(VideoDecoder.isKeyframe(clip[0]), "the first sample of a clip is a keyframe")

        let decoder = VideoDecoder()
        XCTAssertTrue(decoder.image(for: clip[0]).producedFreshPicture)
        XCTAssertTrue(decoder.image(for: clip[1]).producedFreshPicture)
        let lastGood = try XCTUnwrap(decoder.lastGoodImage)

        // What the stall detector does to a decoder it thinks is stuck, and what iOS does to the
        // session at lock.
        decoder.rebuild()

        for sample in clip[2...] {
            let held = decoder.image(for: sample)
            XCTAssertFalse(held.producedFreshPicture,
                           "a rebuilt session must not start on a frame that needs the old one's "
                           + "references")
            XCTAssertTrue(held.image === lastGood, "and the app keeps the last good picture")
        }

        XCTAssertTrue(decoder.image(for: clip[0]).producedFreshPicture,
                      "the next keyframe starts the new session")
        XCTAssertTrue(decoder.image(for: clip[1]).producedFreshPicture)
    }

    // MARK: - Keyframes still get through

    /// The stream that says nothing must still start: its keyframes are found in the video.
    func testAKeyframeWithNoAttachmentIsStillAdmitted() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 1, forceKeyframes: true)
        let stripped = try VideoClipTestSupport.withoutAttachments(clip[0])
        XCTAssertNil(VideoDecoder.notSyncAttachment(stripped))
        XCTAssertTrue(VideoDecoder.isKeyframe(stripped))

        let decoder = VideoDecoder()
        let result = decoder.image(for: stripped)
        XCTAssertTrue(result.producedFreshPicture)
        XCTAssertNotNil(result.image)
    }

    /// An attachment that is wrong the other way. Under the old rule a keyframe marked `NotSync`
    /// would have been refused, and a stream that marked them all would never have started.
    func testAKeyframeWronglyMarkedNotSyncIsStillAdmitted() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 1, forceKeyframes: true)
        let mislabelled = try VideoClipTestSupport.marking(clip[0], notSync: true)
        XCTAssertEqual(VideoDecoder.notSyncAttachment(mislabelled), true)
        XCTAssertTrue(VideoDecoder.isKeyframe(mislabelled))

        let decoder = VideoDecoder()
        XCTAssertTrue(decoder.image(for: mislabelled).producedFreshPicture)
    }

    /// And a P-frame marked as a sync sample is still a P-frame.
    func testAPFrameWronglyMarkedSyncIsStillRefused() throws {
        let mislabelled = try VideoClipTestSupport.marking(try encodedPFrame(), notSync: false)
        XCTAssertEqual(VideoDecoder.notSyncAttachment(mislabelled), false)
        XCTAssertFalse(VideoDecoder.isKeyframe(mislabelled))

        let decoder = VideoDecoder()
        XCTAssertFalse(decoder.image(for: mislabelled).producedFreshPicture)
    }

    // MARK: - The parser against a real encoder

    /// For every sample of a clip the encoder was left to structure by itself, the parser's
    /// answer and the encoder's own `NotSync` marking are the same answer. This is what ties the
    /// hand-built fixtures in `NALUnitInspectorTests` to real bitstreams, and it runs the real
    /// path: the format description's length-prefix size and the sample's block buffer.
    func testTheParserAndTheEncoderAgreeOnEverySampleOfAnHEVCClip() throws {
        try assertParserAgreesWithEncoder(codec: kCMVideoCodecType_HEVC)
    }

    /// The same for H.264, which the decoder also accepts and the parser reads with a different
    /// header layout.
    func testTheParserAndTheEncoderAgreeOnEverySampleOfAnH264Clip() throws {
        try assertParserAgreesWithEncoder(codec: kCMVideoCodecType_H264)
    }

    /// A keyframe the encoder was forced to make carries its type in the video too, and the
    /// inspection reports whether the parameter sets came with it without tripping over them.
    func testAnInspectedKeyframeIsARandomAccessPicture() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 2, forceKeyframes: true)
        for sample in clip {
            let inspection = VideoDecoder.inspect(sample)
            guard case .randomAccess = inspection.kind else {
                return XCTFail("a forced keyframe read as \(inspection.kind)")
            }
            XCTAssertTrue(inspection.isKeyframe)
        }
    }

    // MARK: - Bytes that are not in one piece

    /// A block buffer may chain several pieces of memory. The inspection must read the same
    /// thing from one cut up mid-length-prefix as from the original, for a keyframe and for a
    /// P-frame.
    func testASampleDeliveredInPiecesReadsTheSame() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 6, forceKeyframes: false)
        let pFrame = try XCTUnwrap(clip.dropFirst().first {
            VideoDecoder.notSyncAttachment($0) == true
        }, "the encoder produced only keyframes for this clip")

        for sample in [clip[0], pFrame] {
            let whole = VideoDecoder.inspect(try VideoClipTestSupport.withoutAttachments(sample))
            let pieces = VideoDecoder.inspect(try VideoClipTestSupport.inPieces(sample))
            XCTAssertNotEqual(whole.kind, .unparseable)
            XCTAssertEqual(pieces, whole)
        }
    }

    // MARK: - Samples the parser cannot read

    /// A sample with no data buffer has no video to read, so the attachment rule is all there
    /// is: absent reads as a keyframe, exactly as before.
    func testASampleWithNoDataFallsBackToTheAttachment() throws {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 1, forceKeyframes: true)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(clip[0]))

        var empty: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &empty)
        let sample = try XCTUnwrap(empty, "CMSampleBufferCreate failed (\(status))")
        XCTAssertNil(CMSampleBufferGetDataBuffer(sample))

        let inspection = VideoDecoder.inspect(sample)
        XCTAssertEqual(inspection.kind, .unparseable)
        XCTAssertNil(inspection.notSync)
        XCTAssertTrue(VideoDecoder.isKeyframe(sample))
    }

    // MARK: - Helpers

    /// A sample the **encoder** marked as not a sync sample, so the choice of P-frame owes
    /// nothing to the parser under test.
    private func encodedPFrame() throws -> CMSampleBuffer {
        let clip = try VideoClipTestSupport.encodeClip(frameCount: 6, forceKeyframes: false)
        return try XCTUnwrap(
            clip.dropFirst().first { VideoDecoder.notSyncAttachment($0) == true },
            "the encoder produced only keyframes for this clip, so there is no mid-GOP sample "
            + "to test with")
    }

    private func assertParserAgreesWithEncoder(codec: CMVideoCodecType,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let clip = try VideoClipTestSupport.encodeClip(codec: codec, frameCount: 6,
                                                       forceKeyframes: false)
        var randomAccess = 0
        var others = 0
        for (index, sample) in clip.enumerated() {
            let inspection = VideoDecoder.inspect(sample)
            XCTAssertNotEqual(inspection.kind, .unparseable,
                              "sample \(index) of a real clip must be readable",
                              file: file, line: line)

            let parserSaysKeyframe: Bool
            if case .randomAccess = inspection.kind {
                parserSaysKeyframe = true
                randomAccess += 1
            } else {
                parserSaysKeyframe = false
                others += 1
            }
            XCTAssertEqual(parserSaysKeyframe, inspection.attachmentSaysKeyframe,
                           "sample \(index): the parser read \(inspection.kind), the encoder "
                           + "marked NotSync=\(String(describing: inspection.notSync))",
                           file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(randomAccess, 1, "a clip starts with a keyframe",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(others, 1, "the encoder produced only keyframes for this "
                                    + "clip, so the comparison never saw a non-keyframe",
                                    file: file, line: line)
    }
}
