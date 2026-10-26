import Foundation

/// The recovered `Caps` element encoding — the binary tuple format Rokid Glasses (RV101)
/// speak on the CXR-M command channel. This closes the last gap between `RokidCXRCommand`
/// (the vocabulary) and a byte that can actually be written to a characteristic.
///
/// ## Provenance
///
/// Derived two independent ways that agree byte-for-byte:
///
/// 1. **Static** — the glasses' own `/system/lib64/libcaps.so` (pulled over adb) implements
///    `rokid::Caps::serialize`, `serializeHeader` and `serializeMemberDesc`. The header
///    layout and the member-tag table below are read straight out of those routines, and
///    the type tags match the `NumberMember<T, tag, sizeof(T)>` instantiations in the same
///    library. (`libcxr_service_jni.so` only *imports* `rokid::Caps` — the implementation
///    lives in `libcaps.so`, which is a `DT_NEEDED` of it.)
/// 2. **Empirical** — an Apple PacketLogger HCI capture of a live phone↔glasses session.
///    Every field here was fitted to it, and the encoder in this file re-emits captured
///    packets byte-for-byte, checksum included, for all 402 packets that survive full
///    validation. `RokidCapsCodecTests` carries golden vectors lifted from that capture.
///
/// ## Caps blob
///
/// ```
/// [u32 BE  total]   the whole blob is `total` bytes, including these 4
/// [u8      0x05 ]   format version, constant (not a length)
/// [uleb128 count]   member count
/// [u8 × count  ]    one type tag per member, in value order
/// [values      ]    each member's value, in tag order, each self-delimiting
/// ```
///
/// | tag | meaning       | value encoding                      |
/// |-----|---------------|-------------------------------------|
/// | `V` | void          | *(nothing)*                         |
/// | `i` | int32         | signed LEB128                       |
/// | `u` | uint32        | unsigned LEB128                     |
/// | `l` | int64         | signed LEB128                       |
/// | `k` | uint64        | unsigned LEB128                     |
/// | `f` | float         | 4 bytes, little-endian IEEE-754     |
/// | `d` | double        | 8 bytes, little-endian IEEE-754     |
/// | `S` | string        | `uleb128 byteCount` + UTF-8 bytes   |
/// | `B` | binary        | `u32 BE byteCount` + bytes          |
/// | `O` | nested object | a complete nested Caps blob         |
///
/// The endianness is genuinely mixed: totals and lengths are **big-endian**, floats are
/// **little-endian**, integers are LEB128. Because `O` recurses into a full blob (its own
/// `u32 BE total`, version and tag list), nesting looks like duplicated type tags at a
/// glance — that was the "doubled tags" red herring.
///
/// ## The command tuple
///
/// A request is the four-member tuple `uuSO`:
/// `(route, sequence, channel, object{method, payload})`.
///
/// - `route` is `0x1001` on the command channel; `0x3001` carries audio playback and
///   `0x3003` audio cancellation.
/// - `sequence` is a per-connection counter. It only ever increased in the capture,
///   spanning 0…548 across 402 frames with 21 gaps, so treat it as strictly increasing
///   rather than contiguous.
/// - `channel` is `Dev` / `Ai` / `Med` / `Sys`.
/// - The trailing object holds the method name plus its payload. The payload is a `S`
///   string when the command carries JSON or text, and an `i`/`u` integer when it carries
///   a bare number (`Dev_GlassBrightness` → `5`), and is absent for payload-less methods.
enum RokidCapsCodec {

    /// Format version byte written after the total length. Constant `5` in every captured
    /// frame and in `Caps::serializeHeader`.
    static let version: UInt8 = 0x05

    /// The largest member count accepted on decode. Captured tuples never exceed 4; the
    /// bound only exists so a malformed blob cannot make the decoder allocate wildly.
    static let maximumMembers = 64

    // MARK: - Errors

    enum DecodeError: Error, Equatable {
        case truncated
        case unsupportedVersion(UInt8)
        case tooManyMembers(Int)
        case unknownTag(UInt8)
        case lengthMismatch(declared: Int, actual: Int)
        case valueOutOfRange(tag: Character)
    }

    // MARK: - Encoding

    /// Serialize a tuple to its Caps blob.
    ///
    /// Member types are taken from each value's own `typeTag`, so the caller only has to
    /// supply values in order.
    static func encode(_ members: [RokidCapsValue]) -> [UInt8] {
        var body: [UInt8] = []
        appendUnsignedLEB128(UInt64(members.count), to: &body)
        for member in members {
            body.append(tagByte(member.typeTag))
        }
        for member in members {
            appendValue(member, to: &body)
        }

        var blob = appendBigEndian(UInt32(5 + body.count))
        blob.append(version)
        blob.append(contentsOf: body)
        return blob
    }

    /// ASCII byte for a type tag.
    ///
    /// `UInt8(ascii:)` takes a `Unicode.Scalar`, while `RokidCapsValue.typeTag` is a
    /// `Character`. Every tag is a single ASCII scalar by construction — the getter is a
    /// `switch` over ten cases returning only ASCII literals — so this is a straight
    /// narrowing. The `?` fallback exists so an impossible tag can never crash a display
    /// encoder: it encodes to a byte the decoder rejects with `DecodeError.unknownTag`.
    private static func tagByte(_ tag: Character) -> UInt8 {
        guard let scalar = tag.unicodeScalars.first, scalar.isASCII else { return 0x3F }
        return UInt8(ascii: scalar)
    }

    private static func appendValue(_ value: RokidCapsValue, to out: inout [UInt8]) {
        switch value {
        case .void:
            break
        case .int32(let number):
            appendSignedLEB128(Int64(number), to: &out)
        case .uint32(let number):
            appendUnsignedLEB128(UInt64(number), to: &out)
        case .int64(let number):
            appendSignedLEB128(number, to: &out)
        case .uint64(let number):
            appendUnsignedLEB128(number, to: &out)
        case .float(let number):
            out.append(contentsOf: withUnsafeBytes(of: number.bitPattern.littleEndian) { Array($0) })
        case .double(let number):
            out.append(contentsOf: withUnsafeBytes(of: number.bitPattern.littleEndian) { Array($0) })
        case .string(let text):
            let utf8 = Array(text.utf8)
            appendUnsignedLEB128(UInt64(utf8.count), to: &out)
            out.append(contentsOf: utf8)
        case .binary(let data):
            appendUnsignedLEB128(UInt64(data.count), to: &out)
            out.append(contentsOf: data)
        case .object(let members):
            out.append(contentsOf: encode(members))
        }
    }

    // MARK: - Decoding

    /// Parse one Caps blob starting at `offset`, advancing it past the blob.
    ///
    /// The blob is self-delimiting: its `u32 BE` total says exactly how long it is, so
    /// several frames can be concatenated on one stream and drained one at a time.
    static func decode(_ bytes: [UInt8], offset: inout Int) throws -> [RokidCapsValue] {
        let start = offset
        guard bytes.count >= offset + 5 else { throw DecodeError.truncated }

        let total = Int(readBigEndianUInt32(bytes, offset))
        offset += 4

        let version = bytes[offset]
        offset += 1
        guard version == Self.version else { throw DecodeError.unsupportedVersion(version) }

        let count = Int(try readUnsignedLEB128(bytes, &offset))
        guard count <= maximumMembers else { throw DecodeError.tooManyMembers(count) }
        guard bytes.count >= offset + count else { throw DecodeError.truncated }

        var tags: [UInt8] = []
        tags.reserveCapacity(count)
        for _ in 0..<count {
            tags.append(bytes[offset])
            offset += 1
        }

        var members: [RokidCapsValue] = []
        members.reserveCapacity(count)
        for tag in tags {
            members.append(try readValue(tag, bytes, &offset))
        }

        let consumed = offset - start
        guard consumed == total else {
            throw DecodeError.lengthMismatch(declared: total, actual: consumed)
        }
        return members
    }

    private static func readValue(
        _ tag: UInt8,
        _ bytes: [UInt8],
        _ offset: inout Int
    ) throws -> RokidCapsValue {
        let character = Character(UnicodeScalar(tag))
        switch character {
        case "V":
            return .void
        case "i":
            let raw = try readSignedLEB128(bytes, &offset)
            guard let narrowed = Int32(exactly: raw) else { throw DecodeError.valueOutOfRange(tag: character) }
            return .int32(narrowed)
        case "u":
            let raw = try readUnsignedLEB128(bytes, &offset)
            guard let narrowed = UInt32(exactly: raw) else { throw DecodeError.valueOutOfRange(tag: character) }
            return .uint32(narrowed)
        case "l":
            return .int64(try readSignedLEB128(bytes, &offset))
        case "k":
            return .uint64(try readUnsignedLEB128(bytes, &offset))
        case "f":
            guard bytes.count >= offset + 4 else { throw DecodeError.truncated }
            let pattern = readLittleEndianUInt32(bytes, offset)
            offset += 4
            return .float(Float(bitPattern: pattern))
        case "d":
            guard bytes.count >= offset + 8 else { throw DecodeError.truncated }
            var pattern: UInt64 = 0
            for shift in 0..<8 {
                pattern |= UInt64(bytes[offset + shift]) << (8 * shift)
            }
            offset += 8
            return .double(Double(bitPattern: pattern))
        case "S":
            let length = Int(try readUnsignedLEB128(bytes, &offset))
            guard bytes.count >= offset + length else { throw DecodeError.truncated }
            let text = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
            offset += length
            return .string(text)
        case "B":
            let length = Int(try readUnsignedLEB128(bytes, &offset))
            guard bytes.count >= offset + length else { throw DecodeError.truncated }
            let data = Data(bytes[offset..<offset + length])
            offset += length
            return .binary(data)
        case "O":
            return .object(try decode(bytes, offset: &offset))
        default:
            throw DecodeError.unknownTag(tag)
        }
    }

    // MARK: - Byte primitives

    private static func appendBigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }

    private static func readBigEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func readLittleEndianUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Unsigned LEB128 — one byte per 7 significant bits, low group first, high bit set on
    /// every byte but the last. `Caps::serializeMemberDesc` uses the same writer for the
    /// member count, and `rokid::uleb128Read` in `libcaps.so` reads it back.
    private static func appendUnsignedLEB128(_ value: UInt64, to out: inout [UInt8]) {
        var remaining = value
        repeat {
            var byte = UInt8(truncatingIfNeeded: remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
    }

    /// Signed LEB128 (sign-extended), used by the `i`/`l` tags.
    private static func appendSignedLEB128(_ value: Int64, to out: inout [UInt8]) {
        var remaining = value
        while true {
            let byte = UInt8(truncatingIfNeeded: remaining & 0x7F)
            remaining >>= 7
            let signBitSet = (byte & 0x40) != 0
            let done = (remaining == 0 && !signBitSet) || (remaining == -1 && signBitSet)
            out.append(done ? byte : byte | 0x80)
            if done { return }
        }
    }

    private static func readUnsignedLEB128(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw DecodeError.truncated }
            let byte = bytes[offset]
            offset += 1
            // Guard the shift so a corrupt stream cannot overflow the accumulator.
            guard shift <= 63 else { throw DecodeError.valueOutOfRange(tag: "k") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private static func readSignedLEB128(_ bytes: [UInt8], _ offset: inout Int) throws -> Int64 {
        var result: Int64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw DecodeError.truncated }
            let byte = bytes[offset]
            offset += 1
            guard shift <= 63 else { throw DecodeError.valueOutOfRange(tag: "l") }
            result |= Int64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                if byte & 0x40 != 0, shift < 64 {
                    result |= -(Int64(1) << shift)
                }
                return result
            }
        }
    }
}

/// The iAP2/MFi link frame that carries a Caps blob from the phone to the glasses.
///
/// ```
/// [u8  0xFF][u8 0x5A]   link sync
/// [u16 BE  length  ]    length of the WHOLE frame, counting from the 0xFF
/// [u8     0x40      ]   frame type
/// [u32 BE  timestamp]   microseconds
/// [u8  0x00][u8 0x01]   fixed header tail
/// [Caps            ]    a complete, self-delimiting Caps blob
/// [u8     checksum  ]   two's complement of the sum of every preceding byte
/// ```
///
/// `length` is the total frame length, not a payload count — a distinction that cost real
/// time to spot, because reading it as "payload length" makes a frame appear to end five
/// bytes early. On the wire this frame is itself the payload of an RFCOMM UIH packet whose
/// length field equals the same number, which is why the two agree.
///
/// The checksum is `(0 - sum(bytes[0..<checksumIndex])) & 0xFF`, i.e. all frame bytes from
/// the leading `0xFF` through the last Caps byte. It validates on 3,215 of 3,216
/// fully-parsed captured frames, in both directions. The single exception is a
/// phone-to-glasses frame truncated at a 512-byte ACL fragment boundary (it declares a
/// total of 1,543 bytes inside a 512-byte fragment), which is a reassembly artefact of the
/// capture rather than a disagreement about the format.
enum RokidIAP2Packet {

    static let linkSync: [UInt8] = [0xFF, 0x5A]
    static let frameType: UInt8 = 0x40
    /// Bytes between the length field and the Caps blob: type, timestamp, session id.
    static let headerBytesAfterLength = 7
    /// Bytes before the length field: the two link-sync bytes plus the length itself.
    static let prefixBytes = 4

    /// Session identifier carried at frame offset 9-10, big-endian.
    ///
    /// This was believed constant (`00 01`) because the first capture only ever showed
    /// one value. A second capture from the same phone and firmware shows `00 08` in
    /// 1,003 of 1,012 frames, so the field tracks the connection rather than the format.
    /// It is not known who assigns it or whether the glasses validate it, so it stays a
    /// parameter with the value the first capture used as the default.
    static let defaultSessionID: UInt16 = 0x0001

    /// Route id for ordinary commands: `Dev`, `Ai`, `Med`, `Sys` and also `CXRControl`.
    /// 399 of the 401 captured request frames use it.
    static let commandRoute = RokidCapsRoute.request.rawValue
    /// Route id for the audio-playback channel (`playAudio` outbound, `AI_assistant`
    /// inbound), whose object carries an `ifuu` descriptor rather than a method name.
    static let audioRoute = RokidCapsRoute.audioPlay.rawValue
    /// Route id for audio stop: a bare `(route, sequence)` tuple with no channel or method.
    static let audioStopRoute = RokidCapsRoute.audioStop.rawValue

    // MARK: - Encoding

    /// Frame an arbitrary Caps tuple for the wire.
    ///
    /// - Parameters:
    ///   - caps: the tuple to carry — the caller is responsible for the leading
    ///     `(route, sequence)` members matching the frame's addressee.
    ///   - timestampMicroseconds: frame timestamp; the glasses only need it to increase.
    ///   - sessionID: connection-scoped session id; see `defaultSessionID`.
    static func encode(
        caps: [RokidCapsValue],
        timestampMicroseconds: UInt32,
        sessionID: UInt16 = defaultSessionID
    ) -> [UInt8] {
        let capsBytes = RokidCapsCodec.encode(caps)
        let total = prefixBytes + headerBytesAfterLength + capsBytes.count + 1

        var frame: [UInt8] = linkSync
        frame.append(UInt8(truncatingIfNeeded: total >> 8))
        frame.append(UInt8(truncatingIfNeeded: total))
        frame.append(frameType)
        frame.append(UInt8(truncatingIfNeeded: timestampMicroseconds >> 24))
        frame.append(UInt8(truncatingIfNeeded: timestampMicroseconds >> 16))
        frame.append(UInt8(truncatingIfNeeded: timestampMicroseconds >> 8))
        frame.append(UInt8(truncatingIfNeeded: timestampMicroseconds))
        frame.append(UInt8(truncatingIfNeeded: sessionID >> 8))
        frame.append(UInt8(truncatingIfNeeded: sessionID))
        frame.append(contentsOf: capsBytes)
        frame.append(checksum(frame))
        return frame
    }

    /// Frame one command: builds the `uuSO` tuple and wraps it.
    ///
    /// - Parameters:
    ///   - route: `commandRoute` for ordinary commands.
    ///   - sequence: per-connection counter, echoed back in responses.
    ///   - channel: `Dev` / `Ai` / `Med` / `Sys`.
    ///   - method: the command name, e.g. `Dev_GlassBrightness`.
    ///   - payload: JSON text as `.string`, a bare number as `.int32`/`.uint32`, or `nil`
    ///     for a method that takes no argument.
    static func encodeCommand(
        route: UInt32 = commandRoute,
        sequence: UInt32,
        channel: String,
        method: String,
        payload: RokidCapsValue?,
        timestampMicroseconds: UInt32,
        sessionID: UInt16 = defaultSessionID
    ) -> [UInt8] {
        var object: [RokidCapsValue] = [.string(method)]
        if let payload { object.append(payload) }
        let caps: [RokidCapsValue] = [
            .uint32(route),
            .uint32(sequence),
            .string(channel),
            .object(object),
        ]
        return encode(
            caps: caps,
            timestampMicroseconds: timestampMicroseconds,
            sessionID: sessionID
        )
    }

    /// Frame a `uB` tuple: a route id plus one binary chunk.
    ///
    /// This is the shape of route `0x2002` (photo download) and `0x2003`.
    static func encodeBinary(
        route: UInt32,
        data: Data,
        timestampMicroseconds: UInt32,
        sessionID: UInt16 = defaultSessionID
    ) -> [UInt8] {
        encode(
            caps: [.uint32(route), .binary(data)],
            timestampMicroseconds: timestampMicroseconds,
            sessionID: sessionID
        )
    }

    /// Two's complement of the byte sum — the iAP2 link-packet checksum.
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in bytes { sum = sum &+ byte }
        return (~sum) &+ 1
    }

    // MARK: - Decoding

    /// Session id at frame offset 9-10, or `nil` when the frame is too short.
    static func sessionID(of bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= prefixBytes + headerBytesAfterLength else { return nil }
        return UInt16(bytes[9]) << 8 | UInt16(bytes[10])
    }

    struct Frame: Equatable {
        let route: UInt32
        /// Present on shapes that carry one. `uB`/`uBuk` media frames and `uSO`
        /// notifications do not, which is why this is optional.
        let sequence: UInt32?
        let timestampMicroseconds: UInt32
        /// Connection-scoped id at frame offset 9-10. Reported rather than validated:
        /// the first capture carries `0x0001` in every frame and the second `0x0008` in
        /// 1,003 of 1,012, so no single value is correct across connections.
        let sessionID: UInt16
        let caps: [RokidCapsValue]
    }

    /// Parse one frame. Returns `nil` when the bytes are not a well-formed frame, so a
    /// caller draining a stream can resynchronise by scanning for the next sync word.
    static func decode(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count >= prefixBytes + headerBytesAfterLength + 1 else { return nil }
        guard Array(bytes[0..<2]) == linkSync else { return nil }
        guard bytes[4] == frameType else { return nil }

        let total = Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count >= total, total >= prefixBytes + headerBytesAfterLength + 1 else { return nil }

        let frame = Array(bytes[0..<total])
        guard checksum(Array(frame[0..<(total - 1)])) == frame[total - 1] else { return nil }

        let timestamp = UInt32(frame[5]) << 24
            | UInt32(frame[6]) << 16
            | UInt32(frame[7]) << 8
            | UInt32(frame[8])
        // Deliberately not validated. The session id tracks the connection, so gating on
        // one value would reject every frame from a later session — which is exactly what
        // this line used to do for the second capture.
        let session = UInt16(frame[9]) << 8 | UInt16(frame[10])

        var offset = 11
        guard let caps = try? RokidCapsCodec.decode(frame, offset: &offset) else { return nil }
        guard offset == total - 1 else { return nil }
        guard caps.count >= 2, case .uint32(let route) = caps[0] else { return nil }
        var sequence: UInt32?
        if case .uint32(let value) = caps[1] { sequence = value }
        return Frame(
            route: route,
            sequence: sequence,
            timestampMicroseconds: timestamp,
            sessionID: session,
            caps: caps
        )
    }
}

// MARK: - Routes

/// Route ids carried in the first `u` member of every Caps tuple.
///
/// The route — not the payload — decides the tuple's shape, so these nine cases are the
/// complete addressing vocabulary observed on the wire: 3690 checksum-valid frames across
/// both directions, every one of them type `0x40`.
enum RokidCapsRoute: UInt32, CaseIterable {
    /// `uuSO` = `(route, sequence, channel, object{method[, payload]})`, phone → glasses.
    case request = 0x1001
    /// `uuO` = `(route, sequence, object{method, payload})`, glasses → phone. The sequence
    /// echoes the request's, which is how a reply is correlated with what it answers.
    case reply = 0x1002
    /// `uSO` = `(route, channel, object{method, payload})`, glasses → phone. No sequence:
    /// these are unsolicited state changes (brightness, volume, battery, scene status).
    case notification = 0x1003
    /// `uuSO`, glasses → phone, but the second `u` is a millisecond clock rather than a
    /// small counter. Used for "the user did something" events such as `Ai_TakePhoto`.
    case event = 0x2001
    /// `uB` = `(route, binary chunk)`, glasses → phone. 198 consecutive 480-byte chunks
    /// whose first chunk begins `RIFF….WEBP` — a photo streamed back in chunks.
    case photo = 0x2002
    /// `uB` again, but a single 264-byte chunk of unidentified content. Same shape as
    /// ``photo``; kept distinct because the firmware addresses them separately.
    case opaque = 0x2003
    /// `uuSOuu` — an audio-playback descriptor. The trailing two `u`s are the playback id
    /// and a flag.
    case audioPlay = 0x3001
    /// `uBuk` = `(route, audio chunk, u, k)` — one slice of an encoded audio stream.
    /// Outbound slices carry `ID3`/`Lavf` MP3 or raw frames; inbound slices begin with
    /// `OggS` (Opus). The trailing `k` is a millisecond clock on inbound slices
    /// (1792707896531 is the capture's own epoch) and `0` on outbound ones; the trailing
    /// `u` is a small stream selector, observed only as 3 or 4.
    case audioData = 0x3002
    /// `uu` = `(route, sequence)` only. Stops or acknowledges playback.
    case audioStop = 0x3003
}

// MARK: - Messages

/// One decoded CXR-M message, classified by route.
///
/// `nil` from `decode` means "not a message we model" — audio frames carry playback
/// descriptors instead of a method and are deliberately excluded.
enum RokidCapsMessage: Equatable {
    /// A command this side sends.
    case request(route: UInt32, sequence: UInt32, channel: String, method: String,
                 payload: RokidCapsValue?)
    /// The glasses answering a request; `sequence` matches the request's.
    case reply(route: UInt32, sequence: UInt32, method: String, payload: RokidCapsValue?)
    /// The glasses reporting state nobody asked about.
    case notification(route: UInt32, channel: String, method: String, payload: RokidCapsValue?)

    /// The method name, whatever the shape.
    var method: String {
        switch self {
        case .request(_, _, _, let method, _),
             .reply(_, _, let method, _),
             .notification(_, _, let method, _):
            return method
        }
    }

    /// The channel string, where the shape carries one (replies do not).
    var channel: String? {
        switch self {
        case .request(_, _, let channel, _, _), .notification(_, let channel, _, _):
            return channel
        case .reply:
            return nil
        }
    }

    /// Text payload, which is what every non-audio method observed so far sends.
    var textPayload: String? {
        switch self {
        case .request(_, _, _, _, .string(let text)),
             .reply(_, _, _, .string(let text)),
             .notification(_, _, _, .string(let text)):
            return text
        default:
            return nil
        }
    }

    static func decode(_ bytes: [UInt8]) -> RokidCapsMessage? {
        guard let frame = RokidIAP2Packet.decode(bytes),
              case .uint32(let routeID)? = frame.caps.first,
              let kind = RokidCapsRoute(rawValue: routeID) else { return nil }

        let caps = frame.caps
        switch kind {
        case .request, .event:
            guard caps.count >= 4,
                  case .uint32(let sequence) = caps[1],
                  case .string(let channel) = caps[2],
                  case .object(let members) = caps[3],
                  case .string(let method)? = members.first else { return nil }
            let payload = members.count >= 2 ? members[1] : nil
            guard kind == .request else {
                return .notification(route: routeID, channel: channel, method: method,
                                     payload: payload)
            }
            return .request(route: routeID, sequence: sequence, channel: channel,
                            method: method, payload: payload)

        case .reply:
            guard caps.count >= 3,
                  case .uint32(let sequence) = caps[1],
                  case .object(let members) = caps[2],
                  case .string(let method)? = members.first else { return nil }
            return .reply(route: routeID, sequence: sequence, method: method,
                          payload: members.count >= 2 ? members[1] : nil)

        case .notification:
            guard caps.count >= 3,
                  case .string(let channel) = caps[1],
                  case .object(let members) = caps[2],
                  case .string(let method)? = members.first else { return nil }
            return .notification(route: routeID, channel: channel, method: method,
                                 payload: members.count >= 2 ? members[1] : nil)

        case .photo, .opaque, .audioData, .audioPlay, .audioStop:
            return nil
        }
    }
}

// MARK: - Media transfers

/// A payload-carrying frame: data the glasses stream to us, or audio we stream to them.
///
/// These routes carry no method name, so they are modelled separately from
/// ``RokidCapsMessage``. They are also the only shapes that put a ``RokidCapsValue/binary``
/// member on the wire — which is how the `B` length defect went unnoticed until a photo
/// frame was decoded by hand.
enum RokidMediaTransfer: Equatable {
    /// `uB` on ``RokidCapsRoute/photo`` or ``RokidCapsRoute/opaque``: one chunk of a
    /// larger binary payload. Concatenate `data` across frames; the transfer ends when a
    /// chunk arrives shorter than the full chunk size.
    case binaryChunk(route: UInt32, data: Data)
    /// `uBuk` on ``RokidCapsRoute/audioData``: one slice of an encoded audio stream.
    case audioChunk(route: UInt32, data: Data)

    /// The chunk payload, whichever route it arrived on.
    var data: Data {
        switch self {
        case .binaryChunk(_, let data), .audioChunk(_, let data):
            return data
        }
    }

    static func decode(_ bytes: [UInt8]) -> RokidMediaTransfer? {
        guard let frame = RokidIAP2Packet.decode(bytes),
              let kind = RokidCapsRoute(rawValue: frame.route),
              frame.caps.count >= 2,
              case .binary(let data) = frame.caps[1] else { return nil }
        switch kind {
        case .photo, .opaque:
            return .binaryChunk(route: frame.route, data: data)
        case .audioData:
            return .audioChunk(route: frame.route, data: data)
        default:
            return nil
        }
    }
}
