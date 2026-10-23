/// What to hand the transport. Both modes are genuine unknowns: every capture we have starts
/// mid-session, so it cannot show whether the **phone** builds the `FF 5A` link frame (as the
/// encoder does) or whether iOS's MFi stack wraps a bare Caps blob. Flip this on hardware
/// rather than guessing — both encoders exist and are tested.
enum RokidMFIFraming: Equatable {
    /// Write the whole iAP2 link frame: sync, length, header, Caps, checksum.
    case framed
    /// Write only the Caps blob and let the MFi stack frame it.
    case rawCaps
}

/// Framing policy for the MFi transport.
///
/// Deliberately separate from `RokidMFITransport`: this is pure byte arithmetic over
/// `RokidFrameDrain` and `RokidIAP2Packet`, with no `ExternalAccessory` dependency. Keeping it
/// Foundation-only means it compiles — and its tests run — anywhere, including the standalone
/// `swiftcheck` package, instead of only inside an iOS build.
enum RokidMFIPayload {
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
}
