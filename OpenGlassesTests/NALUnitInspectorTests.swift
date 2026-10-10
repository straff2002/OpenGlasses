import XCTest
@testable import OpenGlasses

/// Plan HW P0. The decoder took a sample's word for whether it was a keyframe, and took silence
/// for "yes". A stream that never says anything then has nothing but keyframes, and a decoder
/// rebuilt mid-stream starts on whatever comes next. The parser reads the answer out of the video
/// instead, and these are its rules, stated on bytes built by hand so that no encoder's habits
/// are baked into them: which NAL types a decoder may start on, which leading pictures it must
/// skip, what it steps over to find the picture, and — most of the file — everything it must
/// refuse to guess about.
final class NALUnitInspectorTests: XCTestCase {

    private typealias Kind = NALUnitInspector.PictureKind

    // MARK: - HEVC: which pictures a decoder may start on

    func testAnIDRWithLeadingPicturesIsRandomAccess() {
        XCTAssertEqual(kind(framed([hevc(19)])),
                       .randomAccess(nalType: 19, leadingMayBeUndecodable: false))
    }

    func testAnIDRWithoutLeadingPicturesIsRandomAccess() {
        XCTAssertEqual(kind(framed([hevc(20)])),
                       .randomAccess(nalType: 20, leadingMayBeUndecodable: false))
    }

    /// A CRA is a place to start, but the leading pictures after it may reference what came
    /// before, so it says so.
    func testACRAIsRandomAccessAndWarnsAboutItsLeadingPictures() {
        XCTAssertEqual(kind(framed([hevc(21)])),
                       .randomAccess(nalType: 21, leadingMayBeUndecodable: true))
    }

    /// BLA_W_LP is the one broken-link type that may still be followed by RASL pictures.
    func testABLAWithLeadingPicturesWarnsAboutThemToo() {
        XCTAssertEqual(kind(framed([hevc(16)])),
                       .randomAccess(nalType: 16, leadingMayBeUndecodable: true))
    }

    func testABLAWithOnlyDecodableLeadingPicturesDoesNot() {
        XCTAssertEqual(kind(framed([hevc(17)])),
                       .randomAccess(nalType: 17, leadingMayBeUndecodable: false))
        XCTAssertEqual(kind(framed([hevc(18)])),
                       .randomAccess(nalType: 18, leadingMayBeUndecodable: false))
    }

    /// 22 and 23 are reserved for random-access types that do not exist yet. They are in the
    /// range the standard promises will stay random access, so they count.
    func testTheReservedRandomAccessTypesCount() {
        XCTAssertEqual(kind(framed([hevc(22)])),
                       .randomAccess(nalType: 22, leadingMayBeUndecodable: false))
        XCTAssertEqual(kind(framed([hevc(23)])),
                       .randomAccess(nalType: 23, leadingMayBeUndecodable: false))
    }

    /// The ordinary frame of a stream, and the one the field report says was passing as a
    /// keyframe.
    func testATrailingPictureIsNotRandomAccess() {
        XCTAssertEqual(kind(framed([hevc(1)])), .nonRandomAccess(nalType: 1))
        XCTAssertEqual(kind(framed([hevc(0)])), .nonRandomAccess(nalType: 0))
    }

    func testARASLPictureIsALeadingPictureToSkip() {
        XCTAssertEqual(kind(framed([hevc(8)])), .leadingSkipped(nalType: 8))
        XCTAssertEqual(kind(framed([hevc(9)])), .leadingSkipped(nalType: 9))
    }

    func testARADLPictureIsALeadingPictureThatDecodes() {
        XCTAssertEqual(kind(framed([hevc(6)])), .leadingDecodable(nalType: 6))
        XCTAssertEqual(kind(framed([hevc(7)])), .leadingDecodable(nalType: 7))
    }

    /// Every slice type that is neither random access nor a leading picture needs what came
    /// before it, including the reserved ones nobody has assigned.
    func testEveryOtherSliceTypeIsNotRandomAccess() {
        for type in UInt8(0)...31 where !(16...23).contains(type) && !(6...9).contains(type) {
            XCTAssertEqual(kind(framed([hevc(type)])), .nonRandomAccess(nalType: type),
                           "type \(type)")
        }
    }

    // MARK: - HEVC: what it steps over

    func testParameterSetsBeforeTheSliceAreSteppedOver() {
        let sample = framed([hevc(32), hevc(33), hevc(34), hevc(19)])
        XCTAssertEqual(kind(sample), .randomAccess(nalType: 19, leadingMayBeUndecodable: false))
    }

    func testAnSEIMessageBeforeTheSliceIsSteppedOver() {
        XCTAssertEqual(kind(framed([hevc(39), hevc(1)])), .nonRandomAccess(nalType: 1))
        XCTAssertEqual(kind(framed([hevc(40), hevc(21)])),
                       .randomAccess(nalType: 21, leadingMayBeUndecodable: true))
    }

    func testAnAccessUnitDelimiterFirstIsSteppedOver() {
        XCTAssertEqual(kind(framed([hevc(35), hevc(32), hevc(33), hevc(34), hevc(39), hevc(20)])),
                       .randomAccess(nalType: 20, leadingMayBeUndecodable: false))
    }

    /// The first slice decides. A picture is one type throughout, so what follows cannot change
    /// the answer, and the parser does not read on to find out.
    func testTheFirstSliceDecides() {
        XCTAssertEqual(kind(framed([hevc(1), hevc(19)])), .nonRandomAccess(nalType: 1))
        // Not even rubbish after the first slice is looked at.
        XCTAssertEqual(kind(framed([hevc(19)]) + [0xFF, 0xFF]),
                       .randomAccess(nalType: 19, leadingMayBeUndecodable: false))
    }

    // MARK: - The length prefix

    /// The prefix size comes from the format description and is not always four.
    func testEveryPrefixSizeFromOneToFourIsRead() {
        for lengthSize in 1...4 {
            let sample = framed([hevc(32), hevc(19)], lengthSize: lengthSize)
            XCTAssertEqual(kind(sample, lengthSize: lengthSize),
                           .randomAccess(nalType: 19, leadingMayBeUndecodable: false),
                           "a \(lengthSize)-byte prefix")
        }
    }

    /// Read with the wrong size, the same bytes are not the same units. Whatever comes out, it
    /// must come out without reading past the buffer.
    func testTheWrongPrefixSizeIsNotMistakenForAKeyframe() {
        let sample = framed([hevc(32), hevc(19)], lengthSize: 4)
        XCTAssertEqual(kind(sample, lengthSize: 3), .unparseable)
        XCTAssertEqual(kind(sample, lengthSize: 2), .unparseable)
        XCTAssertEqual(kind(sample, lengthSize: 1), .unparseable)
    }

    func testAPrefixSizeOutsideOneToFourIsUnparseable() {
        let sample = framed([hevc(19)])
        XCTAssertEqual(kind(sample, lengthSize: 0), .unparseable)
        XCTAssertEqual(kind(sample, lengthSize: 5), .unparseable)
        XCTAssertEqual(kind(sample, lengthSize: -1), .unparseable)
        XCTAssertEqual(kind(sample, lengthSize: 8), .unparseable)
    }

    // MARK: - What it refuses to guess

    func testAnEmptyBufferIsUnparseable() {
        XCTAssertEqual(kind([]), .unparseable)
        XCTAssertEqual(kind([], codec: .h264), .unparseable)
    }

    /// The buffer ends inside a length field.
    func testATruncatedLengthFieldIsUnparseable() {
        XCTAssertEqual(kind([0x00, 0x00, 0x00]), .unparseable)
        XCTAssertEqual(kind(framed([hevc(32)]) + [0x00, 0x00]), .unparseable)
    }

    /// The length says more bytes follow than the buffer holds.
    func testALengthThatOverrunsTheBufferIsUnparseable() {
        var sample = framed([hevc(19)])
        sample.removeLast()
        XCTAssertEqual(kind(sample), .unparseable)
        XCTAssertEqual(kind([0xFF, 0xFF, 0xFF, 0xFF, 0x26, 0x01, 0xAF]), .unparseable)
        // A unit to be stepped over whose length runs past everything behind it, slice and all.
        XCTAssertEqual(kind([0x00, 0x00, 0x00, 0x10, 0x40, 0x01, 0x0C] + framed([hevc(19)])),
                       .unparseable)
    }

    /// A unit too short to hold its own header: nothing, or one byte of a two-byte HEVC header.
    func testALengthShorterThanTheHeaderIsUnparseable() {
        XCTAssertEqual(kind([0x00, 0x00, 0x00, 0x00] + framed([hevc(19)])), .unparseable)
        XCTAssertEqual(kind([0x00, 0x00, 0x00, 0x01, 0x26]), .unparseable)
        XCTAssertEqual(kind([0x00, 0x00, 0x00, 0x00], codec: .h264), .unparseable)
    }

    /// A slice that is a header and nothing else is not a picture.
    func testASliceWithNoDataIsUnparseable() {
        XCTAssertEqual(kind(framed([[19 << 1, 0x01]])), .unparseable)
        XCTAssertEqual(kind(framed([[0x65]]), codec: .h264), .unparseable)
    }

    /// The top bit of a NAL header is always zero. Set, these are not NAL units.
    func testASetForbiddenBitIsUnparseable() {
        XCTAssertEqual(kind(framed([[0x80 | (19 << 1), 0x01, 0xAF]])), .unparseable)
        XCTAssertEqual(kind(framed([hevc(32), [0x80 | (1 << 1), 0x01, 0xAF]])), .unparseable)
        XCTAssertEqual(kind(framed([[0x80 | 0x65, 0x88]]), codec: .h264), .unparseable)
    }

    /// The low three bits of an HEVC header's second byte are never all zero.
    func testAZeroTemporalIdIsUnparseable() {
        XCTAssertEqual(kind(framed([[19 << 1, 0x00, 0xAF]])), .unparseable)
    }

    /// Parameter sets and nothing else: a well-formed sample with no picture in it. There is
    /// nothing to classify, and "not a keyframe" would be a guess.
    func testParameterSetsWithNoSliceAreUnparseable() {
        XCTAssertEqual(kind(framed([hevc(32), hevc(33), hevc(34)])), .unparseable)
        XCTAssertEqual(kind(framed([h264(7), h264(8)]), codec: .h264), .unparseable)
    }

    /// Start-code framing is a different format. A four-byte start code reads as a length of one,
    /// which is too short for an HEVC header and too short for an H.264 slice; a three-byte one
    /// reads as a length far past the end of a small buffer.
    func testAnAnnexBBufferIsNotMistakenForLengthPrefixedUnits() {
        let fourByteHEVC: [UInt8] = [0, 0, 0, 1] + hevc(32) + [0, 0, 0, 1] + hevc(19)
        XCTAssertEqual(kind(fourByteHEVC), .unparseable)
        let threeByteHEVC: [UInt8] = [0, 0, 1] + hevc(32) + [0, 0, 1] + hevc(19)
        XCTAssertEqual(kind(threeByteHEVC), .unparseable)

        let idrH264: [UInt8] = [0, 0, 0, 1] + h264(5)
        XCTAssertEqual(kind(idrH264, codec: .h264), .unparseable)
        let withSetsH264: [UInt8] = [0, 0, 0, 1] + h264(7) + [0, 0, 0, 1] + h264(8)
            + [0, 0, 0, 1] + h264(5)
        XCTAssertEqual(kind(withSetsH264, codec: .h264), .unparseable)
    }

    /// No bytes, however arranged, may take the parser past the end of its buffer. Unsafe buffer
    /// subscripts trap in a debug build, so an over-read here is a crash and not a quiet pass.
    func testNoBytesTakeItPastTheEndOfTheBuffer() {
        var state: UInt64 = 0x2026_1010
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 33)
        }
        for round in 0..<4_000 {
            let count = Int(next()) % 40
            var bytes = (0..<count).map { _ in next() }
            // Half the rounds start with a small, plausible length so the walk gets going.
            if round % 2 == 0, bytes.count >= 4 {
                bytes[0] = 0; bytes[1] = 0; bytes[2] = 0; bytes[3] = next() % 12
            }
            for lengthSize in 0...5 {
                for codec in [NALUnitInspector.Codec.hevc, .h264] {
                    _ = kind(bytes, lengthSize: lengthSize, codec: codec)
                    _ = hasParameterSets(bytes, lengthSize: lengthSize, codec: codec)
                }
            }
        }
    }

    // MARK: - H.264

    func testAnH264IDRIsRandomAccess() {
        XCTAssertEqual(kind(framed([h264(5)]), codec: .h264),
                       .randomAccess(nalType: 5, leadingMayBeUndecodable: false))
    }

    func testAnH264NonIDRSliceIsNotRandomAccess() {
        XCTAssertEqual(kind(framed([h264(1)]), codec: .h264), .nonRandomAccess(nalType: 1))
        // Data partitions are slices too.
        XCTAssertEqual(kind(framed([h264(2)]), codec: .h264), .nonRandomAccess(nalType: 2))
    }

    func testH264ParameterSetsAndSEIBeforeTheIDRAreSteppedOver() {
        XCTAssertEqual(kind(framed([h264(9), h264(7), h264(8), h264(6), h264(5)]), codec: .h264),
                       .randomAccess(nalType: 5, leadingMayBeUndecodable: false))
        XCTAssertEqual(kind(framed([h264(7), h264(8), h264(5)], lengthSize: 2),
                            lengthSize: 2, codec: .h264),
                       .randomAccess(nalType: 5, leadingMayBeUndecodable: false))
    }

    /// The two headers are laid out differently, so the codec has to be the right one: an HEVC
    /// IDR read as H.264 is not an IDR.
    func testTheCodecDecidesHowTheHeaderIsRead() {
        XCTAssertNotEqual(kind(framed([hevc(19)]), codec: .h264),
                          .randomAccess(nalType: 5, leadingMayBeUndecodable: false))
        XCTAssertEqual(kind(framed([h264(5, referenceIdc: 0)]), codec: .hevc), .unparseable,
                       "0x05 0x88 as an HEVC header has a zero temporal id")
    }

    // MARK: - Parameter sets

    func testAnHEVCSampleWithParameterSetsSaysSo() {
        XCTAssertTrue(hasParameterSets(framed([hevc(32), hevc(33), hevc(34), hevc(19)])))
        XCTAssertTrue(hasParameterSets(framed([hevc(35), hevc(19), hevc(34)])),
                      "wherever in the sample they are")
        XCTAssertTrue(hasParameterSets(framed([hevc(33)])))
    }

    func testAnHEVCSampleWithoutParameterSetsSaysSo() {
        XCTAssertFalse(hasParameterSets(framed([hevc(19)])))
        XCTAssertFalse(hasParameterSets(framed([hevc(35), hevc(39), hevc(1)])))
        XCTAssertFalse(hasParameterSets([]))
    }

    func testAnH264SampleReportsItsParameterSets() {
        XCTAssertTrue(hasParameterSets(framed([h264(7), h264(8), h264(5)]), codec: .h264))
        XCTAssertTrue(hasParameterSets(framed([h264(1), h264(8)]), codec: .h264))
        XCTAssertFalse(hasParameterSets(framed([h264(9), h264(6), h264(5)]), codec: .h264))
    }

    /// It stops at the first unit it cannot read and answers from what it had seen: sets found
    /// before the damage count, sets after it do not.
    func testParameterSetsAreReportedUpToTheFirstUnreadableUnit() {
        XCTAssertTrue(hasParameterSets(framed([hevc(32)]) + [0xFF, 0xFF, 0xFF, 0xFF, 0x26]))
        XCTAssertFalse(hasParameterSets([0xFF, 0xFF, 0xFF, 0xFF] + framed([hevc(32)])))
        XCTAssertFalse(hasParameterSets(framed([hevc(32)]), lengthSize: 0))
    }

    // MARK: - Codec and names

    func testTheMediaSubTypeNamesTheCodec() {
        XCTAssertEqual(NALUnitInspector.codec(forMediaSubType: fourCC("hvc1")), .hevc)
        XCTAssertEqual(NALUnitInspector.codec(forMediaSubType: fourCC("hev1")), .hevc)
        XCTAssertEqual(NALUnitInspector.codec(forMediaSubType: fourCC("avc1")), .h264)
        XCTAssertEqual(NALUnitInspector.codec(forMediaSubType: fourCC("avc3")), .h264)
        XCTAssertNil(NALUnitInspector.codec(forMediaSubType: fourCC("jpeg")))
        XCTAssertNil(NALUnitInspector.codec(forMediaSubType: fourCC("BGRA")))
        XCTAssertNil(NALUnitInspector.codec(forMediaSubType: 0))
    }

    /// The log's words for a random-access picture are a fixed set of four.
    func testRandomAccessPicturesHaveFixedNames() {
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 19), "idr")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 20), "idr")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 5), "idr")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 21), "cra")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 16), "bla")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 17), "bla")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 18), "bla")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 22), "irap")
        XCTAssertEqual(NALUnitInspector.randomAccessName(nalType: 23), "irap")
    }

    // MARK: - Fixtures

    /// An HEVC NAL unit: the two-byte header (type in bits 1...6 of the first byte, layer 0,
    /// temporal id 0 so `nuh_temporal_id_plus1` is 1) and a little payload.
    private func hevc(_ type: UInt8, payload: [UInt8] = [0xAF, 0x10, 0x80]) -> [UInt8] {
        [type << 1, 0x01] + payload
    }

    /// An H.264 NAL unit: the one-byte header (`nal_ref_idc` above the five-bit type).
    private func h264(_ type: UInt8, referenceIdc: UInt8 = 3,
                      payload: [UInt8] = [0x88, 0x84, 0x00]) -> [UInt8] {
        [(referenceIdc << 5) | type] + payload
    }

    /// Each unit behind a big-endian length of `lengthSize` bytes, as a sample's data buffer
    /// carries them.
    private func framed(_ units: [[UInt8]], lengthSize: Int = 4) -> [UInt8] {
        units.flatMap { unit -> [UInt8] in
            let prefix = (0..<lengthSize).map { index in
                UInt8((unit.count >> (8 * (lengthSize - 1 - index))) & 0xFF)
            }
            return prefix + unit
        }
    }

    private func kind(_ bytes: [UInt8], lengthSize: Int = 4,
                      codec: NALUnitInspector.Codec = .hevc) -> Kind {
        bytes.withUnsafeBytes {
            NALUnitInspector.firstSliceKind($0, lengthSize: lengthSize, codec: codec)
        }
    }

    private func hasParameterSets(_ bytes: [UInt8], lengthSize: Int = 4,
                                  codec: NALUnitInspector.Codec = .hevc) -> Bool {
        bytes.withUnsafeBytes {
            NALUnitInspector.hasParameterSets($0, lengthSize: lengthSize, codec: codec)
        }
    }

    private func fourCC(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
