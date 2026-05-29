import Foundation
import Combine
import UIKit
import WebRTC

/// Signaling message exchanged with the expert over the WebSocket relay. Pure/Codable so encoding can
/// be unit-tested without a live connection.
struct SignalingMessage: Codable, Equatable {
    enum Kind: String, Codable { case join, offer, answer, candidate, bye }
    let type: Kind
    var room: String?
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
}

/// Minimal WebSocket signaling client (SDP/ICE relay).
final class ExpertSignalingClient {
    private let task: URLSessionWebSocketTask
    var onMessage: ((SignalingMessage) -> Void)?

    init?(url: String) {
        guard let u = URL(string: url) else { return nil }
        task = URLSession(configuration: .default).webSocketTask(with: u)
    }

    func connect() {
        task.resume()
        receiveLoop()
    }

    func send(_ message: SignalingMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { NSLog("[Signaling] send error: %@", error.localizedDescription) }
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                NSLog("[Signaling] receive error: %@", error.localizedDescription)
                return
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(SignalingMessage.self, from: data) {
                    self.onMessage?(decoded)
                }
                self.receiveLoop()
            }
        }
    }
}

/// Pushes `UIImage` frames from the glasses into a WebRTC video source.
final class GlassesVideoCapturer: RTCVideoCapturer {
    func push(_ image: UIImage) {
        guard let pixelBuffer = image.toCVPixelBuffer() else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestampNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
        delegate?.capturer(self, didCapture: frame)
    }
}

/// Real peer-to-peer WebRTC transport (Plan L). Streams the glasses camera + mic to a remote expert
/// and plays the expert's audio back, using a WebSocket signaling relay + STUN/TURN from Config.
///
/// The library is bundled; `isAvailable` is true. `start()` still requires a configured signaling URL
/// (and TURN for cross-network use) — it throws a clear message otherwise. The live connection path
/// is not unit-tested (needs two peers + servers).
@MainActor
final class WebRTCPeerTransport: ExpertStreamTransport {
    var displayName: String { ExpertStreamKind.webrtc.label }
    var isAvailable: Bool { true }
    private(set) var isStreaming = false

    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var capturer: GlassesVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var signaling: ExpertSignalingClient?
    private var coordinator: PeerDelegate?
    private var frameSub: AnyCancellable?
    private var room: String = ""

    func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
        let signalingURL = Config.expertSignalingURL.trimmingCharacters(in: .whitespaces)
        guard !signalingURL.isEmpty else {
            throw ExpertStreamError.transportUnavailable(
                "WebRTC needs a signaling server. Set the Expert Signaling URL in Field Assist settings, or use the MJPEG transport.")
        }
        guard let signaling = ExpertSignalingClient(url: signalingURL) else {
            throw ExpertStreamError.transportUnavailable("Invalid signaling URL.")
        }

        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        self.factory = factory

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        var iceServers = [RTCIceServer(urlStrings: [Config.expertStunURL])]
        let turn = Config.expertTurnURL.trimmingCharacters(in: .whitespaces)
        if !turn.isEmpty {
            iceServers.append(RTCIceServer(urlStrings: [turn],
                                           username: Config.expertTurnUsername,
                                           credential: Config.expertTurnCredential))
        }
        config.iceServers = iceServers

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let coordinator = PeerDelegate()
        self.coordinator = coordinator
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: coordinator) else {
            throw ExpertStreamError.transportUnavailable("Could not create the WebRTC peer connection.")
        }
        self.peerConnection = pc

        // Outbound video from the glasses frames.
        let videoSource = factory.videoSource()
        self.videoSource = videoSource
        let capturer = GlassesVideoCapturer(delegate: videoSource)
        self.capturer = capturer
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "glasses_video")
        pc.add(videoTrack, streamIds: ["glasses_stream"])

        // Outbound audio (mic). Inbound expert audio plays out automatically.
        let audioSource = factory.audioSource(with: constraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "glasses_audio")
        pc.add(audioTrack, streamIds: ["glasses_stream"])

        // Throttle frames (~12fps) into the encoder.
        var lastPush = Date.distantPast
        frameSub = framePublisher.sink { [weak capturer] image in
            let now = Date()
            guard now.timeIntervalSince(lastPush) > 0.08 else { return }
            lastPush = now
            capturer?.push(image)
        }

        room = "openglasses-\(UUID().uuidString.prefix(8))"

        // Wire signaling.
        coordinator.onIceCandidate = { [weak self] candidate in
            self?.signaling?.send(SignalingMessage(
                type: .candidate, room: self?.room,
                sdp: nil, candidate: candidate.sdp,
                sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
        }
        signaling.onMessage = { [weak self] message in
            Task { @MainActor in self?.handleSignaling(message) }
        }
        signaling.connect()
        self.signaling = signaling
        signaling.send(SignalingMessage(type: .join, room: room))

        // Create and send the offer.
        let offer = try await pc.offer(for: constraints)
        try await pc.setLocalDescription(offer)
        signaling.send(SignalingMessage(type: .offer, room: room, sdp: offer.sdp))

        // Hand the audio session to the call (pause TTS + wake word) — Plan M3.
        ExpertCallAudioCoordinator.shared.beginCall()

        isStreaming = true
        // Join URL the expert opens (the web client joins the same room on the signaling server).
        return "\(signalingURL)?room=\(room)"
    }

    func stop() async {
        signaling?.send(SignalingMessage(type: .bye, room: room))
        frameSub?.cancel(); frameSub = nil
        signaling?.close(); signaling = nil
        peerConnection?.close(); peerConnection = nil
        capturer = nil; videoSource = nil; coordinator = nil; factory = nil
        isStreaming = false
        // Return the audio session to the normal voice loop.
        ExpertCallAudioCoordinator.shared.endCall()
    }

    private func handleSignaling(_ message: SignalingMessage) {
        guard let pc = peerConnection else { return }
        switch message.type {
        case .answer:
            if let sdp = message.sdp {
                pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                    if let error { NSLog("[WebRTC] setRemoteDescription error: %@", error.localizedDescription) }
                }
            }
        case .candidate:
            if let sdp = message.candidate {
                pc.add(RTCIceCandidate(sdp: sdp, sdpMLineIndex: message.sdpMLineIndex ?? 0, sdpMid: message.sdpMid)) { _ in }
            }
        case .bye:
            Task { await stop() }
        default:
            break
        }
    }
}

/// ObjC peer-connection delegate, kept off the main actor; forwards ICE candidates to the transport.
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    var onIceCandidate: ((RTCIceCandidate) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - UIImage → CVPixelBuffer

private extension UIImage {
    func toCVPixelBuffer() -> CVPixelBuffer? {
        guard let cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
