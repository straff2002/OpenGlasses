import AVFoundation
import Foundation

/// Live diarized transcription over Deepgram's streaming WebSocket. Conforms to
/// `DiarizationProvider`: the shared audio engine's float32 buffers go in (converted to
/// linear16 mono), and `DiarizedSegment`s come out via `onSegment`.
///
/// The deterministic part — Deepgram JSON → `DiarizedSegment` — lives in
/// `DeepgramResponseParser` and is unit-tested. This class is the live transport around it and
/// is device-pending: it never blocks the caption path, connects lazily on the first audio
/// buffer (so the socket carries the engine's real sample rate), and silently no-ops audio
/// while not connected so the caller's existing pipeline is unaffected.
@MainActor
final class DeepgramSTTService: ObservableObject, DiarizationProvider {
    enum ConnectionState: Equatable {
        case idle, connecting, connected, error(String)
    }

    var onSegment: ((DiarizedSegment) -> Void)?
    @Published private(set) var state: ConnectionState = .idle

    /// Runtime gate for cloud egress. Defaults to the live `Config.isDiarizationConfigured`
    /// (opt-in + key + **not** HIPAA); injectable so tests can drive the invariant without the
    /// Keychain. Checked on `start()` *and* every `sendAudio` so a mid-session HIPAA flip (or a
    /// revoked opt-in) stops audio leaving the device immediately — the start-time gate alone
    /// would let a live stream keep flowing.
    var isConfigured: () -> Bool = { Config.isDiarizationConfigured }

    private var wantsConnection = false
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?

    // MARK: - DiarizationProvider

    /// Arm the provider. The socket opens on the first `sendAudio` so it can use the buffer's
    /// real sample rate.
    func start() {
        guard isConfigured() else {
            state = .error("Diarization not available")
            return
        }
        wantsConnection = true
        state = .connecting
    }

    func stop() {
        wantsConnection = false
        sendControl(["type": "CloseStream"])  // flush any buffered final
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        state = .idle
    }

    func sendAudio(_ buffer: AVAudioPCMBuffer) {
        // Runtime invariant: the moment diarization stops being configured (HIPAA flipped on, or
        // opt-in revoked) mid-session, stop egressing audio and tear the socket down. The next
        // captured buffer closes the stream even if nothing else told us to stop.
        guard isConfigured() else {
            if wantsConnection || webSocketTask != nil { stop() }
            return
        }
        if wantsConnection, webSocketTask == nil {
            connect(sampleRate: Int(buffer.format.sampleRate.rounded()))
        }
        guard state == .connected, let task = webSocketTask else { return }
        let data = PCMConverter.linear16Mono(from: buffer)
        guard !data.isEmpty else { return }
        task.send(.data(data)) { error in
            if let error {
                PrivacyLog.speech(.diarization, .sendFailed, error: SafeErrorSummary(error))
            }
        }
    }

    // MARK: - Private

    private func connect(sampleRate: Int) {
        let key = Config.deepgramAPIKey
        guard !key.isEmpty, let url = Config.deepgramStreamingURL(sampleRate: sampleRate) else {
            state = .error("Deepgram not configured")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()
        state = .connected
        receive()
    }

    private func sendControl(_ message: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                Task { @MainActor in
                    if let text { self.handle(text) }
                    self.receive()
                }
            case .failure(let error):
                Task { @MainActor in self.state = .error(error.localizedDescription) }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segment = DeepgramResponseParser.parseStreaming(json) else { return }
        onSegment?(segment)
    }
}
