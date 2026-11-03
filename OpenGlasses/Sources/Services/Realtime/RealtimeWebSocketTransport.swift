import Foundation

protocol RealtimeConnectionTransport: AnyObject {
    var onOpen: ((String?) -> Void)? { get set }
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)? { get set }
    var onError: ((Error?) -> Void)? { get set }
    var audioPacketInterval: TimeInterval { get set }
    var httpStatusCode: Int? { get }
    func authorize(_ request: URLRequest) async throws
    func start(_ request: URLRequest) throws
    func receive() async throws -> Data
    func send(_ json: [String: Any])
    func perform(_ work: @escaping () -> Void)
    func cancel()
}

/// Shared socket mechanics. One connection owns one delegate: a late close from a previous
/// socket cannot invoke a newly installed callback. Ordered sending waits for each completion.
final class RealtimeWebSocketTransport: NSObject, URLSessionWebSocketDelegate, RealtimeConnectionTransport, @unchecked Sendable {
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let queue = DispatchQueue(label: "realtime.socket.send", qos: .userInitiated)
    private var pending: [(URLSessionWebSocketTask, String, Bool)] = []
    private var sending = false
    private var nextAudioTime: DispatchTime = .now()
    private var cancelled = false
    var audioPacketInterval: TimeInterval = 0
    private var socket: URLSessionWebSocketTask?
    private var sharingPermission: CloudProcessingLease?
    private let route: NetworkRoute
    init(route: NetworkRoute = .geminiLiveSession) { self.route = route; super.init() }
    var httpStatusCode: Int? { (socket?.response as? HTTPURLResponse)?.statusCode }
    @MainActor
    func authorize(_ request: URLRequest) async throws {
        guard let url = request.url else { throw CloudProcessingRefusal.invalidDestination }
        sharingPermission = try await CloudProcessingConsent.shared.authorize(url: url, scope: .liveSession)
    }
    func start(_ request: URLRequest) throws {
        try MedicalEgressGuard.check(route)
        guard let url = request.url else { throw RealtimeConnectionConfiguration.ValidationError.invalidEndpoint }
        if case .failure = EndpointPolicy.validate(url: url, for: route, build: .current) {
            throw RealtimeConnectionConfiguration.ValidationError.invalidEndpoint
        }
        socket = try webSocketTask(with: request)
        socket?.resume()
    }
    func receive() async throws -> Data {
        guard let socket else { throw CancellationError() }
        switch try await socket.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw CancellationError()
        }
    }
    func send(_ json: [String: Any]) {
        if let socket { send(json, via: socket) }
    }

    func webSocketTask(with request: URLRequest) throws -> URLSessionWebSocketTask {
        guard let url = request.url, let lease = sharingPermission, lease.isValid,
              try CloudProcessingTerms(url: url, scope: .liveSession) == lease.terms else {
            throw CloudProcessingRefusal.permissionRequired
        }
        let task = session.webSocketTask(with: request)
        task.delegate = CloudProcessingTransferDelegate(lease: lease, session: session, url: url)
        lease.onWithdrawal { [weak task] in task?.cancel(with: .policyViolation, reason: nil) }
        guard lease.isValid else { task.cancel(); throw CloudProcessingRefusal.withdrawn }
        return task
    }

    /// Encoding, base64 work and protocol state are serialized on this queue as well.
    func perform(_ work: @escaping () -> Void) { queue.async(execute: work) }
    func send(_ json: [String: Any], via socket: URLSessionWebSocketTask) {
        // Called by perform(), or independently from a legacy adapter.
        queue.async {
            guard !self.cancelled, self.sharingPermission?.isValid == true,
                  let data = try? JSONSerialization.data(withJSONObject: json),
                  let text = String(data: data, encoding: .utf8) else { return }
            if ["input_audio_mute.commit", "session.close"].contains(json["type"] as? String ?? "") {
                self.pending.removeAll { $0.2 }
            }
            guard self.pending.count < 250 else {
                self.onError?(RealtimeTransportError.backpressure)
                self.cancelled = true
                self.pending.removeAll()
                return
            }
            self.pending.append((socket, text, json["type"] as? String == "input_audio_buffer.append"))
            self.pump()
        }
    }
    private func pump() {
        guard !sending, !cancelled, !pending.isEmpty else { return }
        sending = true
        let (socket, text, audio) = pending.removeFirst()
        let deadline = audio && audioPacketInterval > 0 ? max(.now(), nextAudioTime) : .now()
        if audio { nextAudioTime = deadline + audioPacketInterval }
        queue.asyncAfter(deadline: deadline) {
            guard !self.cancelled, self.sharingPermission?.isValid == true else { self.sending = false; self.pending.removeAll(); socket.cancel(); return }
            socket.send(.string(text)) { error in
                self.queue.async {
                    self.sending = false
                    if let error { self.onError?(error) }
                    else { self.pump() }
                }
            }
        }
    }
    func cancel() {
        queue.async { self.cancelled = true; self.pending.removeAll() }
        session.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { onOpen?(`protocol`) }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { onClose?(closeCode, reason) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onError?(error) }
    }
}

enum RealtimeTransportError: LocalizedError {
    case backpressure
    var errorDescription: String? { String(localized: "The realtime connection cannot keep up with microphone audio. Reconnecting.") }
}

/// Retains only a partial sample packet. Fixed-size packets are paced by the transport.
struct RealtimeAudioPacketizer {
    let packetBytes: Int
    private var remainder = Data()

    init(packetBytes: Int) {
        self.packetBytes = packetBytes
    }

    mutating func append(_ data: Data) -> [Data] {
        remainder.append(data)
        var packets: [Data] = []
        while remainder.count >= packetBytes {
            packets.append(Data(remainder.prefix(packetBytes)))
            remainder.removeFirst(packetBytes)
        }
        return packets
    }
    mutating func reset() { remainder.removeAll() }
}
