import Foundation

/// Plan HW P0 — what kind of picture a compressed sample is, read from the sample itself (pure).
///
/// The decoder used to ask the sample's attachments whether it was a keyframe, and to read a
/// missing answer as "yes". That attachment is a courtesy the *encoder's wrapper* adds;
/// VideoToolbox's own encoder sets it, which is why every test passed, and nothing obliges the
/// glasses stream to. A stream that never sets it makes every sample read as a keyframe, and a
/// decoder rebuilt mid-stream then starts on whatever arrives next. The video says what it is
/// regardless of who wrapped it: every coded picture begins with a NAL unit whose header names its
/// type, and the type says whether a decoder may start there.
///
/// This file is where "a keyframe" is defined, so it reads both codecs `VideoDecoder` accepts,
/// although the glasses only send HEVC today. It takes bytes and returns a verdict; the CoreMedia
/// side (finding the bytes and the length-prefix size) lives in `VideoDecoder`.
///
/// It never guesses. Anything it cannot read exactly — a length that runs off the end, a header
/// that breaks the format's own rules, a sample with no picture in it — is `.unparseable`, and
/// the caller falls back to the attachment for that sample.
enum NALUnitInspector {

    enum Codec: Equatable {
        case h264
        case hevc
    }

    /// The codec a format description's media subtype names. `avc1`/`avc3` and `hvc1`/`hev1`
    /// differ only in where the parameter sets travel, which does not change how a slice is
    /// read. Anything else is not ours to parse.
    static func codec(forMediaSubType subType: UInt32) -> Codec? {
        switch subType {
        case 0x6176_6331, 0x6176_6333: return .h264   // 'avc1', 'avc3'
        case 0x6876_6331, 0x6865_7631: return .hevc   // 'hvc1', 'hev1'
        default: return nil
        }
    }

    enum PictureKind: Equatable {
        /// A picture a decoder can start on. `leadingMayBeUndecodable` is true for the two HEVC
        /// types whose leading pictures may reference pictures from before them, which a decoder
        /// that started here never saw: CRA (21) and BLA_W_LP (16).
        case randomAccess(nalType: UInt8, leadingMayBeUndecodable: Bool)
        /// HEVC RASL_N (8) and RASL_R (9): a leading picture that may reference pictures from
        /// before its random-access point. Decodable mid-stream, rubbish straight after a start.
        case leadingSkipped(nalType: UInt8)
        /// HEVC RADL_N (6) and RADL_R (7): a leading picture that references nothing from before
        /// its random-access point, so it decodes wherever the decoder started.
        case leadingDecodable(nalType: UInt8)
        /// Every other coded picture. It needs the pictures before it.
        case nonRandomAccess(nalType: UInt8)
        /// The bytes could not be read as length-prefixed NAL units holding a picture.
        case unparseable
    }

    /// Classifies the sample by its **first** coded-slice NAL unit, skipping the parameter sets,
    /// access-unit delimiters and SEI messages that may come before it. Every slice of one
    /// picture carries the same type, so the first is the picture's.
    ///
    /// `bytes` is the sample's data: NAL units each prefixed by a big-endian length of
    /// `lengthSize` bytes (1...4, from the format description). Start-code framing is not this
    /// format and is not recognised.
    ///
    /// H.264 note: only an IDR picture (type 5) counts as random access. A stream that marks its
    /// recovery points with an SEI message and never sends an IDR has none as far as this parser
    /// can tell; `KeyframeHold`'s patience is what keeps such a stream from being held forever.
    static func firstSliceKind(_ bytes: UnsafeRawBufferPointer, lengthSize: Int,
                               codec: Codec) -> PictureKind {
        var offset = 0
        while true {
            switch nextUnit(in: bytes, at: &offset, lengthSize: lengthSize, codec: codec) {
            case .malformed, .end:
                // Running out of units without meeting a picture is as unreadable as a bad
                // length: there is nothing here to classify.
                return .unparseable
            case .unit(let type, let length):
                guard isCodedSlice(type, codec: codec) else { continue }
                // A slice that is all header and no data is not a slice. Requiring one byte of
                // payload costs a real stream nothing and stops a four-byte start code, which
                // reads as a length of one, from passing as a picture.
                guard length > headerSize(of: codec) else { return .unparseable }
                return kind(ofSlice: type, codec: codec)
            }
        }
    }

    /// Whether the sample carries its own parameter sets (HEVC VPS 32, SPS 33, PPS 34; H.264
    /// SPS 7, PPS 8). Stops quietly at the first unit it cannot read and answers from what it had
    /// seen by then — this is evidence for a log line, not a gate.
    static func hasParameterSets(_ bytes: UnsafeRawBufferPointer, lengthSize: Int,
                                 codec: Codec) -> Bool {
        var offset = 0
        while case .unit(let type, _) = nextUnit(in: bytes, at: &offset, lengthSize: lengthSize,
                                                 codec: codec) {
            switch codec {
            case .hevc: if (32...34).contains(type) { return true }
            case .h264: if type == 7 || type == 8 { return true }
            }
        }
        return false
    }

    /// The fixed word the log uses for a random-access NAL type. The two codecs' numbers do not
    /// overlap (H.264 has only 5; HEVC uses 16...23), so the type alone is enough.
    static func randomAccessName(nalType: UInt8) -> String {
        switch nalType {
        case 5, 19, 20: return "idr"
        case 21: return "cra"
        case 16, 17, 18: return "bla"
        default: return "irap"
        }
    }

    // MARK: - Walking the units

    private enum Step {
        case unit(type: UInt8, length: Int)
        /// Nothing left: the buffer ended exactly on a unit boundary, or was empty to begin with.
        case end
        case malformed
    }

    /// Bytes in a NAL unit header: two for HEVC, one for H.264.
    private static func headerSize(of codec: Codec) -> Int {
        codec == .hevc ? 2 : 1
    }

    /// Reads the unit at `offset` and moves `offset` past it. Every read is bounds-checked
    /// against the buffer first; a declared length is believed only once it is known to fit.
    private static func nextUnit(in bytes: UnsafeRawBufferPointer, at offset: inout Int,
                                 lengthSize: Int, codec: Codec) -> Step {
        guard (1...4).contains(lengthSize) else { return .malformed }
        let remaining = bytes.count - offset
        if remaining == 0 { return .end }
        guard remaining >= lengthSize else { return .malformed }   // a truncated length field

        var length = 0
        for index in 0..<lengthSize {
            length = (length << 8) | Int(bytes[offset + index])
        }
        let start = offset + lengthSize
        guard length >= headerSize(of: codec), length <= bytes.count - start else {
            return .malformed
        }

        let first = bytes[start]
        // forbidden_zero_bit: set means this is not a NAL unit header, whatever else it is.
        guard first & 0x80 == 0 else { return .malformed }

        let type: UInt8
        switch codec {
        case .hevc:
            // nuh_temporal_id_plus1 is never zero in a real header. Checking it is one more way
            // for bytes that are not NAL units to fail to look like them.
            guard bytes[start + 1] & 0x07 != 0 else { return .malformed }
            type = (first >> 1) & 0x3F
        case .h264:
            type = first & 0x1F
        }

        offset = start + length
        return .unit(type: type, length: length)
    }

    // MARK: - Reading the type

    /// HEVC: types 0...31 are coded slices (VCL); 32 and up are parameter sets, delimiters, SEI
    /// and the rest. H.264: 1...5 are slices (5 is IDR, 2...4 data partitions).
    private static func isCodedSlice(_ type: UInt8, codec: Codec) -> Bool {
        switch codec {
        case .hevc: return type <= 31
        case .h264: return (1...5).contains(type)
        }
    }

    private static func kind(ofSlice type: UInt8, codec: Codec) -> PictureKind {
        switch codec {
        case .h264:
            return type == 5
                ? .randomAccess(nalType: type, leadingMayBeUndecodable: false)
                : .nonRandomAccess(nalType: type)
        case .hevc:
            switch type {
            case 16...23:
                // IRAP: BLA 16...18, IDR 19 and 20, CRA 21, and 22/23 reserved for future IRAP
                // types. Only CRA and BLA_W_LP may be followed by RASL pictures.
                return .randomAccess(nalType: type,
                                     leadingMayBeUndecodable: type == 21 || type == 16)
            case 8, 9: return .leadingSkipped(nalType: type)
            case 6, 7: return .leadingDecodable(nalType: type)
            default: return .nonRandomAccess(nalType: type)
            }
        }
    }
}
