import XCTest
import CoreMedia
import CoreVideo
import UIKit
@testable import OpenGlasses

/// Plan HW P1. What the frame pipeline does with a raw frame, driven through the method that
/// takes a sample buffer so no SDK frame is ever built here.
///
/// Before this, a raw frame the SDK's helper could not draw (which is every raw frame once the
/// phone is locked) had no data buffer and no picture, read as `.empty`, and was dropped without
/// stamping either liveness clock. A whole stream of those read as a dead link: the detector
/// rebuilt the stream, the rebuilt one delivered more of the same, and recovery backed off and
/// finally stopped the camera. The pixels had been arriving the entire time.
final class GlassesFramePipelineTests: XCTestCase {

    /// The lock-screen case: pixels, no helper picture. It becomes a fresh picture, and the
    /// stream it came from reads as alive.
    func testARawFrameTheHelperCouldNotDrawBecomesAFreshPicture() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_32BGRA)

        let picture = pipeline.picture(helperImage: nil, sampleBuffer: sample)

        let image = try XCTUnwrap(picture.image, "the pixels arrived, so there is a picture")
        XCTAssertTrue(picture.isFresh)
        XCTAssertEqual(image.cgImage?.width, 16)
        XCTAssertEqual(image.cgImage?.height, 8)
        XCTAssertEqual(pipeline.verdict(), .healthy)
        XCTAssertEqual(pipeline.lifetimeSampleCount, 1)
        // A stream that has delivered is judged by the gap between frames, not by the longer
        // wait a new stream gets for its first one. Three seconds on, that is a stall: the
        // proof that this frame stamped the clocks rather than slipping past them.
        XCTAssertEqual(pipeline.verdict(now: Date().addingTimeInterval(3)), .linkStalled)
    }

    func testABiPlanarRawFrameBecomesAFreshPictureToo() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let picture = pipeline.picture(helperImage: nil, sampleBuffer: sample)

        XCTAssertNotNil(picture.image)
        XCTAssertTrue(picture.isFresh)
        XCTAssertEqual(pipeline.lifetimeSampleCount, 1)
    }

    /// In the foreground the helper draws the frame, and its picture is the one used. Nothing
    /// about a foreground raw stream changes.
    func testWithAHelperPictureTheHelpersPictureIsUsed() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_32BGRA)
        let helper = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

        let picture = pipeline.picture(helperImage: helper, sampleBuffer: sample)

        XCTAssertTrue(picture.image === helper, "the frame must not be converted a second time")
        XCTAssertTrue(picture.isFresh)
        XCTAssertEqual(pipeline.lifetimeSampleCount, 1)
    }

    /// Pixels nobody can show are handled exactly like no pixels: nothing to publish, and
    /// neither clock stamped, so a stream of them is a link stall and gets the stream rebuilt
    /// rather than a decoder that was never involved.
    func testAnUnsupportedPixelFormatYieldsNothingAndStampsNeitherClock() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_OneComponent8)

        for _ in 0..<3 {
            let picture = pipeline.picture(helperImage: nil, sampleBuffer: sample)
            XCTAssertNil(picture.image)
            XCTAssertFalse(picture.isFresh)
        }

        XCTAssertEqual(pipeline.lifetimeSampleCount, 0)
        // Still waiting for a first frame, so still on the first-frame grace...
        XCTAssertEqual(pipeline.verdict(now: Date().addingTimeInterval(3)), .healthy)
        // ...and when that runs out it is the link that is called stalled, not the decoder.
        XCTAssertEqual(pipeline.verdict(now: Date().addingTimeInterval(6)), .linkStalled)
    }

    /// The stall record asks how many samples arrived before a teardown, after the teardown has
    /// reset the pipeline. The count it subtracts must survive that.
    func testTheLifetimeSampleCountSurvivesAReset() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_32BGRA)
        _ = pipeline.picture(helperImage: nil, sampleBuffer: sample)
        _ = pipeline.picture(helperImage: nil, sampleBuffer: sample)
        XCTAssertEqual(pipeline.lifetimeSampleCount, 2)

        pipeline.reset()
        XCTAssertEqual(pipeline.lifetimeSampleCount, 2, "a teardown is not a reason to forget")
        pipeline.restartClocks()
        pipeline.rebuildDecoder()
        XCTAssertEqual(pipeline.lifetimeSampleCount, 2)

        _ = pipeline.picture(helperImage: nil, sampleBuffer: sample)
        XCTAssertEqual(pipeline.lifetimeSampleCount, 3)
    }

    /// The silence the stall record reports is measured from the last sample.
    func testSecondsSinceTheLastSampleRestartsWhenOneArrives() throws {
        let pipeline = GlassesFramePipeline()
        let sample = try makeRawSample(kCVPixelFormatType_32BGRA)
        _ = pipeline.picture(helperImage: nil, sampleBuffer: sample)

        let later = Date().addingTimeInterval(10)
        XCTAssertEqual(pipeline.secondsSinceLastSample(now: later), 10, accuracy: 1)
    }

    // MARK: - Fixtures

    /// A sample as a raw stream delivers one: an image buffer and no data buffer.
    private func makeRawSample(_ format: OSType) throws -> CMSampleBuffer {
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, format,
                                         attributes as CFDictionary, &created)
        let pixelBuffer = try XCTUnwrap(created, "CVPixelBufferCreate failed (\(status))")

        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixelBuffer,
                                                     formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
            sampleBufferOut: &sample)
        let sampleBuffer = try XCTUnwrap(sample)
        XCTAssertNil(CMSampleBufferGetDataBuffer(sampleBuffer), "a raw sample has no data buffer")
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(sampleBuffer))
        return sampleBuffer
    }
}
