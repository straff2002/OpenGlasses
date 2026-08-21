import Foundation

/// Plan CQ P4 — the command set of the OEM capture protocol.
///
/// # What is and isn't attested
///
/// This enum lists **only** the commands and payloads that appear in the community
/// reconstruction. It deliberately does not cover every mode the hardware supports, because the
/// opcodes for the rest are not documented anywhere we can check, and a guessed byte sent to a
/// camera on someone's face is not a guess worth making. Where a mode is known to exist but its
/// encoding is not, it is absent from this type and named in the gaps list below rather than
/// invented.
///
/// Everything here is unverified against hardware.
///
/// ## Known gaps (present on the device, encoding unknown)
/// - Discrete photo mode, video start/stop, audio-recording start/stop as distinct opcodes.
///   Only the composite AI-capture control payload below is attested.
/// - Media enumeration and time sync.
/// - Any command for *leaving* the livestream mode ``startLivestream`` enters. That absence is
///   the reason livestreaming stays a Plan CQ P7 spike and is not modelled as a normal command.
enum CaptureCommand: Equatable {

    /// Device control family. Behaviour is selected by the payload, not by a distinct opcode.
    case control(ControlAction)

    /// Enter livestream mode. **No confirmed exit command exists** — see the gaps list.
    case startLivestream

    /// An opcode we have not modelled. The escape hatch exists so a capture-log replay can be
    /// driven through this type without first extending it, not so callers can invent commands.
    case raw(opcode: UInt8, payload: [UInt8])

    /// Payload-selected behaviours of the ``control(_:)`` family.
    enum ControlAction: Equatable {
        /// Take an AI capture and push its thumbnail back over the link.
        ///
        /// The thumbnail is on the order of a kilobyte — enough to confirm a capture happened,
        /// nowhere near enough to read text off. Full resolution needs the network transfer in
        /// Plan CQ P6.
        case aiCaptureWithThumbnail
        /// Put the device's microphone into speech-recognition mode.
        ///
        /// Note this is mutually exclusive with the camera on this hardware: the device cannot
        /// listen and look at once, which is why `CameraCapabilities.concurrentWithMic` exists.
        case startMicrophone
        /// Play audio through the device speaker.
        case speakerPlayback

        /// The attested payload bytes.
        var payload: [UInt8] {
            switch self {
            case .aiCaptureWithThumbnail: return [0x02, 0x01, 0x06, 0x02, 0x02, 0x02]
            case .startMicrophone:        return [0x02, 0x01, 0x07]
            case .speakerPlayback:        return [0x02, 0x01, 0x10]
            }
        }
    }

    // MARK: - Opcodes

    /// Device control.
    static let controlOpcode: UInt8 = 0x41
    /// Livestream entry.
    static let livestreamOpcode: UInt8 = 0x67

    var opcode: UInt8 {
        switch self {
        case .control: return Self.controlOpcode
        case .startLivestream: return Self.livestreamOpcode
        case .raw(let opcode, _): return opcode
        }
    }

    var payload: [UInt8] {
        switch self {
        case .control(let action): return action.payload
        case .startLivestream: return []
        case .raw(_, let payload): return payload
        }
    }

    /// The frame to write to the device.
    var packet: CapturePacket {
        CapturePacket(command: opcode, payload: payload)
    }
}

/// Opcodes the device sends to us, unprompted or in reply.
enum CaptureNotification: Equatable {

    /// A capture finished and its data can now be requested.
    case captureReady
    /// A JPEG thumbnail, delivered inline.
    case thumbnail(Data)
    /// One frame of microphone audio: OPUS, 16 kHz mono, roughly 20 ms per frame.
    ///
    /// The device stops sending after a few seconds of silence and expects the host to restart
    /// it — a transport-level behaviour that Plan CQ P5 has to handle, not a stream ending.
    case microphoneAudio(Data)
    /// A reply to a control command. May or may not carry a readable status — see
    /// ``CaptureControlReply``.
    case controlReply(CaptureControlReply)
    /// An opcode we do not model.
    case unrecognised(opcode: UInt8, payload: [UInt8])

    static let captureReadyOpcode: UInt8 = 0x73
    static let thumbnailOpcode: UInt8 = 0xFD
    static let microphoneAudioOpcode: UInt8 = 0x59

    /// Interpret a decoded frame.
    static func from(_ packet: CapturePacket) -> CaptureNotification {
        switch packet.command {
        case captureReadyOpcode:
            return .captureReady
        case thumbnailOpcode:
            return .thumbnail(Data(packet.payload))
        case microphoneAudioOpcode:
            return .microphoneAudio(Data(packet.payload))
        case CaptureCommand.controlOpcode:
            return .controlReply(CaptureControlReply.parse(packet.payload))
        default:
            return .unrecognised(opcode: packet.command, payload: packet.payload)
        }
    }
}
