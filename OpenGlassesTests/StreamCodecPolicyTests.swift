import XCTest
import MWDATCamera
@testable import OpenGlasses

/// Plan EO P1. The stream was requested as raw pixels, which the glasses link cannot carry at
/// 720p, so the SDK's ladder stepped the source down and the delivered rate sagged regardless of
/// what the settings said. Asking for `hvc1` moves the decode to the phone.
///
/// Two rules have to hold for that to be safe. The setting must never resolve to something
/// nobody chose — an older build's value or a typo has to read as the default, not as an error.
/// And what happens to a frame must be decided by the frame, not by the codec we asked for:
/// a firmware that decodes for us hands the SDK helper a picture, and decoding that again would
/// be nonsense.
final class StreamCodecPolicyTests: XCTestCase {

    /// The default is HEVC — that is the entire point of the plan.
    func testTheDefaultCodecIsHEVC() {
        XCTAssertEqual(StreamCodecPolicy.videoCodec(for: StreamCodecPolicy.hevcSetting), .hvc1)

        let saved = UserDefaults.standard.string(forKey: "cameraCodec")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "cameraCodec") }
            else { UserDefaults.standard.removeObject(forKey: "cameraCodec") }
        }
        UserDefaults.standard.removeObject(forKey: "cameraCodec")
        XCTAssertEqual(Config.cameraCodec, StreamCodecPolicy.hevcSetting,
                       "an unset preference must read as HEVC")
        Config.setCameraCodec(StreamCodecPolicy.rawSetting)
        XCTAssertEqual(Config.cameraCodec, StreamCodecPolicy.rawSetting,
                       "and the setting has to survive being written")
    }

    /// Raw is the way back. If a firmware mishandles compressed video the wearer must be able to
    /// fix it from Settings rather than by reinstalling.
    func testRawIsReachable() {
        XCTAssertEqual(StreamCodecPolicy.videoCodec(for: StreamCodecPolicy.rawSetting), .raw)
    }

    /// A value nobody recognises is somebody's typo or an older build's string. It falls to the
    /// default rather than to `.raw`, because falling to raw would silently undo the plan.
    func testAnUnknownSettingFallsToHEVC() {
        for setting in ["", "h264", "HEVC", "hvc1", "Raw", "true"] {
            XCTAssertEqual(StreamCodecPolicy.videoCodec(for: setting), .hvc1,
                           "\(setting) is not a value we write, so it must read as the default")
        }
    }

    /// The four shapes a delivered frame can have, read from the frame itself.
    func testFrameShapeIsReadFromTheFrameNotTheCodec() {
        XCTAssertEqual(StreamCodecPolicy.shape(helperProducedImage: true, hasDataBuffer: false,
                                               hasImageBuffer: true),
                       .picture)
        XCTAssertEqual(StreamCodecPolicy.shape(helperProducedImage: false, hasDataBuffer: true,
                                               hasImageBuffer: false),
                       .compressed)
        XCTAssertEqual(StreamCodecPolicy.shape(helperProducedImage: false, hasDataBuffer: false,
                                               hasImageBuffer: true),
                       .rawPixels)
        XCTAssertEqual(StreamCodecPolicy.shape(helperProducedImage: false, hasDataBuffer: false,
                                               hasImageBuffer: false),
                       .empty)
    }

    /// Each shape has exactly one thing to do with it.
    func testEachShapeHasOneAction() {
        XCTAssertEqual(StreamCodecPolicy.action(for: .picture), .emit)
        XCTAssertEqual(StreamCodecPolicy.action(for: .compressed), .decode)
        XCTAssertEqual(StreamCodecPolicy.action(for: .rawPixels), .convert)
        XCTAssertEqual(StreamCodecPolicy.action(for: .empty), .drop)
    }

    /// The risk the shape rule exists to remove: a stream that arrives already decoded — a
    /// raw stream, or an SDK/firmware that decodes hvc1 for us — hands the helper a picture
    /// *and* may still carry a data buffer. That must emit, not decode a second time.
    func testAFrameThatArrivesDecodedIsNeverDecodedAgain() {
        let shape = StreamCodecPolicy.shape(helperProducedImage: true, hasDataBuffer: true,
                                            hasImageBuffer: false)
        XCTAssertEqual(shape, .picture, "the helper's picture settles it")
        XCTAssertEqual(StreamCodecPolicy.action(for: shape), .emit)
    }

    /// Plan HW P1. A raw frame in the foreground has its pixels *and* a picture from the helper.
    /// The helper's picture is used, exactly as before the fourth shape existed: converting is
    /// for the frame the helper could not draw, and a foreground raw stream must not change.
    func testARawFrameTheHelperDrewIsStillAPicture() {
        let shape = StreamCodecPolicy.shape(helperProducedImage: true, hasDataBuffer: false,
                                            hasImageBuffer: true)
        XCTAssertEqual(shape, .picture)
        XCTAssertEqual(StreamCodecPolicy.action(for: shape), .emit)
    }

    /// Plan HW P1. With the phone locked the helper draws nothing, and a raw frame used to read
    /// as `.empty` and be dropped although every pixel had arrived. It is its own shape now, and
    /// what is done with it is a conversion, not a drop.
    func testARawFrameTheHelperCouldNotDrawIsConvertedNotDropped() {
        let shape = StreamCodecPolicy.shape(helperProducedImage: false, hasDataBuffer: false,
                                            hasImageBuffer: true)
        XCTAssertEqual(shape, .rawPixels)
        XCTAssertEqual(StreamCodecPolicy.action(for: shape), .convert)
    }

    /// Compressed bytes outrank pixels. A sample that somehow carried both is the decoder's:
    /// the bytes are what the stream sent.
    func testCompressedBytesOutrankAnImageBuffer() {
        XCTAssertEqual(StreamCodecPolicy.shape(helperProducedImage: false, hasDataBuffer: true,
                                               hasImageBuffer: true),
                       .compressed)
    }
}
