import Foundation

// MARK: - Request (pure)

/// The Deepgram streaming URL for a dictation turn (Plan JM P2). Pure, so what leaves the phone in
/// the query — the model, the format, and the vocabulary as keyterms — is tested without a socket.
///
/// The same endpoint the diarized captions use, configured for one speaker asking a question: no
/// diarisation, interim results for the live transcript, smart formatting, endpointing on, and the
/// P0 vocabulary as `keyterm` prompts so model numbers and refrigerant names are heard as written.
enum DeepgramDictationRequest {

    static let endpoint = "wss://api.deepgram.com/v1/listen"

    /// Keyterm prompting is a Nova-3 feature; another model gets no keyterms rather than a refusal.
    static let keytermModelPrefix = "nova-3"
    /// Deepgram bounds keyterm prompting by total tokens. The vocabulary is ordered most-specific
    /// first (the job's own equipment, then the vault, then the glossary), so the cap trims the
    /// generic end.
    static let maxKeyterms = 50
    /// A keyterm is a word or a short phrase; anything longer is not a term worth prompting.
    static let maxKeytermLength = 60
    /// Endpointing in milliseconds: Deepgram finalises a segment after this much silence, which is
    /// what lets the last final arrive promptly once the turn closes.
    static let endpointingMilliseconds = 300

    /// The keyterms for a vocabulary: trimmed, de-duplicated case-insensitively, bounded in length
    /// and count, in the vocabulary's own order.
    static func keyterms(from vocabulary: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for raw in vocabulary {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maxKeytermLength else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
            if terms.count == maxKeyterms { break }
        }
        return terms
    }

    /// The socket URL at the capture's real sample rate.
    static func url(sampleRate: Int, model: String, vocabulary: [String]) -> URL? {
        var items: [(String, String)] = [
            ("encoding", "linear16"),
            ("sample_rate", String(sampleRate)),
            ("channels", "1"),
            ("model", model),
            ("diarize", "false"),
            ("interim_results", "true"),
            ("smart_format", "true"),
            ("endpointing", String(endpointingMilliseconds)),
        ]
        if model.hasPrefix(keytermModelPrefix) {
            items += keyterms(from: vocabulary).map { ("keyterm", $0) }
        }
        var components = URLComponents(string: endpoint)
        // Encoded by hand rather than through `queryItems`, which leaves `+` and `&`-adjacent
        // characters as they are: a `+` in "R-410A + oil" would otherwise reach the server as a space.
        components?.percentEncodedQuery = items
            .map { "\(encode($0.0))=\(encode($0.1))" }
            .joined(separator: "&")
        return components?.url
    }

    /// RFC 3986 unreserved characters pass; everything else is percent-encoded.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

// MARK: - Transcript (pure)

/// What Deepgram has heard so far in one dictation turn. Each streaming `Results` message carries
/// the current segment: interim ones replace each other, a final one is kept and the next segment
/// starts. The text the turn delivers is every final plus an interim that never got its final
/// (the socket closed first) — never less than the wearer saw on screen.
struct DeepgramDictationTranscript: Equatable {
    private(set) var finals: [String] = []
    private(set) var interim: String = ""

    mutating func apply(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !trimmed.isEmpty { finals.append(trimmed) }
            interim = ""
        } else {
            interim = trimmed
        }
    }

    var text: String {
        (finals + (interim.isEmpty ? [] : [interim])).joined(separator: " ")
    }

    var isEmpty: Bool { text.isEmpty }
}

// MARK: - Transport

/// Dictation through Deepgram's streaming socket (Plan JM P2). A separate service from
/// `DeepgramSTTService` rather than a mode on it: captions and dictation have different switches,
/// different routes and a different end — a caption stream runs until it is stopped, a dictation
/// turn closes, waits briefly for its last final and hands back one transcript.
///
/// **The gate is re-read on every buffer.** `isAllowed` (the live `CloudDictationGate`, which folds
/// in HIPAA, the wearer's choice, the organisation pin, the key and the medical guard) is checked
/// before the socket is built and before each buffer is sent; the first buffer after it turns false
/// tears the socket down, so a mid-utterance flip stops the audio at once.
@MainActor
final class DeepgramDictationService {

    enum State: Equatable {
        case idle
        /// Started; the socket opens on the first buffer, at that buffer's real sample rate.
        case armed
        case connected
        /// `CloseStream` sent; waiting (bounded) for the last final.
        case closing
    }

    private(set) var state: State = .idle

    /// The egress gate. Injectable so a test can flip it between two buffers.
    var isAllowed: () -> Bool = { CloudDictationGate.live.isConfigured(provider: .deepgram) }
    var apiKey: () -> String = { Config.deepgramAPIKey }
    var model: () -> String = { Config.diarizationModel }

    /// The live transcript after each message, for the screen and for re-arming the silence window.
    var onTranscript: ((String) -> Void)?
    /// The stream stopped before the turn ended — the gate closed or the socket failed — with a
    /// fixed reason token. The caller ends the turn with what was heard.
    var onStopped: ((String) -> Void)?

    private var transcript = DeepgramDictationTranscript()
    private var vocabulary: [String] = []
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sharingPermission: CloudProcessingLease?
    private var permissionTask: Task<Void, Never>?
    private var permissionGeneration = 0
    private var closeWaiter: CheckedContinuation<String, Never>?
    private var closeGeneration = 0

    /// What has been heard so far this turn.
    var currentText: String { transcript.text }

    /// Arm a new turn. Returns false, sending nothing, when the gate is closed.
    @discardableResult
    func start(vocabulary: [String]) -> Bool {
        // A previous turn still waiting for its final keeps what it heard and lets go of its socket.
        if closeWaiter != nil { completeClose() }
        tearDownSocket()
        transcript = DeepgramDictationTranscript()
        guard isAllowed() else {
            state = .idle
            PrivacyLog.speech(.cloudDictation, .providerUnavailable, detail: PrivacyToken("deepgram"))
            return false
        }
        self.vocabulary = vocabulary
        state = .armed
        return true
    }

    /// One buffer, already linear16 mono at `sampleRate`.
    func sendAudio(_ data: Data, sampleRate: Int) {
        // Runtime invariant: the moment cloud dictation stops being allowed (HIPAA flipped on, the
        // choice revoked, an organisation pin), stop sending and tear the socket down.
        guard isAllowed() else {
            if state == .armed || state == .connected || webSocketTask != nil {
                stopEarly(reason: "gateClosed")
            }
            return
        }
        if let permission = sharingPermission, !permission.isValid {
            stopEarly(reason: "sharingWithdrawn")
            return
        }
        if state == .armed, webSocketTask == nil {
            connect(sampleRate: sampleRate)
        }
        guard state == .connected, let task = webSocketTask, !data.isEmpty else { return }
        task.send(.data(data)) { error in
            if let error {
                PrivacyLog.speech(.cloudDictation, .sendFailed, error: SafeErrorSummary(error))
            }
        }
    }

    /// End the turn: send `CloseStream`, wait up to `closeTimeout` for Deepgram's last final, and
    /// return everything heard. Never longer than the timeout, whatever the server does.
    func finish(closeTimeout: TimeInterval = 1.5) async -> String {
        guard state == .connected, webSocketTask != nil else {
            let text = transcript.text
            tearDownSocket()
            state = .idle
            return text
        }
        state = .closing
        sendControl(["type": "CloseStream"])
        closeGeneration += 1
        let generation = closeGeneration
        return await withCheckedContinuation { continuation in
            closeWaiter = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(closeTimeout, 0) * 1_000_000_000))
                guard let self, self.closeGeneration == generation else { return }
                self.completeClose()
            }
        }
    }

    /// Drop the turn without waiting (the turn was cancelled).
    func cancel() {
        if closeWaiter != nil { completeClose() }
        tearDownSocket()
        state = .idle
    }

    // MARK: - Private

    private func connect(sampleRate: Int) {
        let key = apiKey()
        guard !key.isEmpty,
              let url = DeepgramDictationRequest.url(sampleRate: sampleRate, model: model(),
                                                     vocabulary: vocabulary) else {
            stopEarly(reason: "notConfigured")
            return
        }
        // The request is built here, so the medical rule is checked on this line too.
        guard MedicalEgressGuard.allows(.deepgramDictation) else {
            stopEarly(reason: "medicalLocalOnly")
            return
        }
        guard sharingPermission?.isValid == true else {
            guard permissionTask == nil else { return }
            let generation = permissionGeneration
            permissionTask = Task { @MainActor [weak self] in
                do {
                    let permission = try await CloudProcessingConsent.shared.authorize(url: url, scope: .speechRecognition)
                    guard let self, self.permissionGeneration == generation, !Task.isCancelled,
                          self.state == .armed, self.isAllowed() && MedicalEgressGuard.allows(.deepgramDictation) else { return }
                    self.permissionTask = nil
                    self.sharingPermission = permission
                    self.connect(sampleRate: sampleRate)
                } catch {
                    guard let self, self.permissionGeneration == generation else { return }
                    self.permissionTask = nil
                    self.stopEarly(reason: "sharingPermissionRequired")
                }
            }
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        guard let permission = sharingPermission, permission.isValid else { return }
        task.delegate = CloudProcessingTransferDelegate(lease: permission, session: session, url: url)
        permission.onWithdrawal { [weak task] in task?.cancel(with: .policyViolation, reason: nil) }
        task.resume()
        state = .connected
        PrivacyLog.speech(.cloudDictation, .started, count: DeepgramDictationRequest.keyterms(from: vocabulary).count,
                          detail: PrivacyToken("deepgram"))
        receive(on: task)
    }

    private func sendControl(_ message: [String: Any]) {
        guard sharingPermission?.isValid == true, let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            let text: String?
            var failure: Error?
            switch result {
            case .success(.string(let s)): text = s
            case .success(.data(let d)): text = String(data: d, encoding: .utf8)
            case .success: text = nil
            case .failure(let error): text = nil; failure = error
            }
            Task { @MainActor in
                guard let self, self.webSocketTask === task else { return }   // a socket from an earlier turn
                if let failure {
                    self.socketEnded(error: failure)
                    return
                }
                if let text { self.handle(text) }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // Deepgram answers `CloseStream` with its last results, then a `Metadata` message: that is
        // the end of the turn, whatever the timeout still has left.
        if json["type"] as? String == "Metadata", state == .closing {
            completeClose()
            return
        }
        guard let segment = DeepgramResponseParser.parseStreaming(json) else { return }
        transcript.apply(text: segment.text, isFinal: segment.isFinal)
        onTranscript?(transcript.text)
    }

    private func socketEnded(error: Error) {
        if state == .closing {
            completeClose()   // the server closed after its last final — the ordinary end
            return
        }
        PrivacyLog.speech(.cloudDictation, .recognitionFailed, detail: PrivacyToken("socketFailed"),
                          error: SafeErrorSummary(error))
        stopEarly(reason: "socketFailed")
    }

    private func stopEarly(reason: String) {
        tearDownSocket()
        state = .idle
        PrivacyLog.speech(.cloudDictation, .stopped, detail: PrivacyToken(reason))
        onStopped?(reason)
    }

    private func completeClose() {
        guard let waiter = closeWaiter else { return }
        closeWaiter = nil
        let text = transcript.text
        tearDownSocket()
        state = .idle
        waiter.resume(returning: text)
    }

    private func tearDownSocket() {
        permissionGeneration += 1
        permissionTask?.cancel()
        permissionTask = nil
        sharingPermission = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
