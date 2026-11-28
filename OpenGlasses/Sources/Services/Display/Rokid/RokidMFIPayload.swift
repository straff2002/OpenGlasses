/// What the MFi transport writes for one encoded command.
///
/// **Settled on hardware: write the bare Caps blob (`.rawCaps`).** On an `EASession`, iOS owns the
/// iAP2 link layer. It adds the `FF 5A` envelope (sync, length, type, timestamp, session id,
/// checksum) itself, which is why every HCI-level capture shows one. The glasses' session handler
/// hands each payload it receives straight to the Caps parser, and that parser wants a blob: a
/// big-endian total that does not exceed the bytes it was given, then the version byte `0x05` at
/// offset 4. A framed write has `0x40` (the link type byte) at offset 4. The parse fails, the
/// handler returns an error, and the glasses tear the session down, so every later write names a
/// session that no longer exists. That is what a framed probe looks like from the phone: the session
/// opens, accepts writes and never answers.
///
/// The same holds on the way in: a read from the session is a bare blob, with no envelope to strip
/// (see ``RokidCapsDrain``).
///
/// `.framed` stays, for the probe only. It is the shape a BLE (GATT) link would carry, and it is
/// what a framed write looks like when someone needs to see the session die again.
enum RokidMFIFraming: Equatable {
    /// Write the whole iAP2 link frame: sync, length, header, Caps, checksum. Kills an MFi session.
    case framed
    /// Write only the Caps blob and let iOS frame it. What an MFi session accepts.
    case rawCaps
}

/// The MFi protocols the glasses offer, and how a session on them is written.
///
/// Kept apart from `RokidMFITransport` so these facts compile everywhere: the transport imports
/// `ExternalAccessory` and is left out of the phone-only store build (Apple asks a build that links
/// it for an MFi product id), while the tests and the `Info.plist` guard still need the names.
enum RokidMFIProtocol {
    /// The two `mfi.eap` names in the glasses' `cxr-service.json`, in preference order:
    /// `com.rokid.global.aiglasses` (EAP protocol id 195) first, then `com.rokid.aiglasses` (194).
    ///
    /// **The order matters.** The glasses advertise both. A session on 194 opens, but the CXR
    /// service never sends a byte on it; it answers only on 195, the protocol Rokid's own app
    /// opens (seen in a cold-connect capture, 2026-11-21).
    ///
    /// **Not declared in the committed `Info.plist`, on purpose.** iOS only opens an `EASession`
    /// for a protocol listed under `UISupportedExternalAccessoryProtocols`, and App Review rejects
    /// a build that lists an MFi protocol unless the accessory maker has registered that app with
    /// Apple's MFi program. Registration is per app: Rokid is an MFi licensee and registered its own
    /// app, but not this one. Add both strings to `Info.plist` locally for a hardware spike and never
    /// commit them; `RokidAccessoryProtocolGuardTests` fails if they land.
    static let strings = [
        "com.rokid.global.aiglasses",
        "com.rokid.aiglasses",
    ]

    /// The EAP protocol id the glasses' `cxr-service.json` gives each of ``strings``. The connect
    /// message names the session by this number, not by its string.
    static let ids: [String: UInt32] = [
        "com.rokid.global.aiglasses": 195,
        "com.rokid.aiglasses": 194,
    ]

    /// What a write puts on the session: the framing the glasses accept (``RokidMFIFraming``).
    static let framing: RokidMFIFraming = .rawCaps
}

/// Framing policy for the MFi transport.
///
/// Deliberately separate from `RokidMFITransport`: this is pure byte arithmetic over
/// `RokidFrameDrain` and `RokidIAP2Packet`, with no `ExternalAccessory` dependency. Keeping it
/// Foundation-only means it compiles, and its tests run, anywhere, instead of only inside an
/// iOS build.
enum RokidMFIPayload {

    /// Bytes a link frame spends around its Caps blob: sync and length (4), type, timestamp and
    /// session id (7), and the trailing checksum (1). Stripping a frame for `.rawCaps` removes
    /// exactly this many.
    static let envelopeOverhead = RokidIAP2Packet.prefixBytes
        + RokidIAP2Packet.headerBytesAfterLength + 1

    /// What actually goes on the wire for one encoded command.
    static func payload(for bytes: [UInt8], framing: RokidMFIFraming) -> [UInt8] {
        switch framing {
        case .framed:
            return bytes
        case .rawCaps:
            // Leave anything we cannot prove is a frame completely alone.
            return rawCapsPayload(from: bytes) ?? bytes
        }
    }

    /// The Caps blob inside a complete link frame, or `nil` if `frame` is not one.
    static func rawCapsPayload(from frame: [UInt8]) -> [UInt8]? {
        guard RokidFrameDrain.isFrame(frame) else { return nil }
        let start = RokidIAP2Packet.prefixBytes + RokidIAP2Packet.headerBytesAfterLength
        let end = frame.count - 1
        guard end > start else { return nil }
        return Array(frame[start..<end])
    }

    /// The Caps tuple carried by `bytes`, whichever shape they arrived in: a whole link frame (a
    /// BLE notification, or a framed probe) or a bare blob (a read from an MFi session).
    ///
    /// Either way the tuple must lead with a `u` route and have a second member, the shape every
    /// route shares, so a decoder downstream can read `caps[0]` and `caps[1]` without checking.
    static func caps(in bytes: [UInt8]) -> [RokidCapsValue]? {
        if let frame = RokidIAP2Packet.decode(bytes) { return frame.caps }
        guard RokidCapsDrain.isBlob(bytes) else { return nil }
        var offset = 0
        guard let caps = try? RokidCapsCodec.decode(bytes, offset: &offset),
              caps.count >= 2,
              case .uint32 = caps[0] else { return nil }
        return caps
    }
}
