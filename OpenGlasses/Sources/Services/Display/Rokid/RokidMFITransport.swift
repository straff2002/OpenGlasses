// The MFi transport links ExternalAccessory, which the phone-only store build must not: Apple asks
// a build that links it for an MFi product id. Everything this file needs from the protocol itself
// lives in RokidMFIProtocol, which compiles everywhere.
#if !AVENKIN_PHONE_ONLY
import Combine
import ExternalAccessory
import Foundation

/// Why an MFi session could not be opened or used. Separate from `GlassesDisplayError`
/// because these failures are all diagnosable from the phone side: "no accessory in the MFi
/// list" and "iOS refused the session" have different fixes.
enum RokidMFIError: LocalizedError, Equatable {
    /// No accessory is connected over the MFi transport.
    case noAccessory
    /// An accessory is connected but advertises none of our protocol strings. Carries the
    /// accessory names and every protocol string seen, because that list is exactly what says
    /// whether `Info.plist` needs a different entry.
    case unsupportedProtocol(accessories: [String], advertised: [String])
    /// `EASession` returned nil: iOS matched no accessory for the declared protocol, or the
    /// session is already open — Classic MFi usually allows one, and Rokid's own app may hold it.
    case sessionCreationFailed(protocolString: String)
    /// The session opened but vended no input/output stream.
    case streamsUnavailable
    case notConnected
    case writeFailed
    /// Writes are arriving faster than the session takes them; see `RokidWriteQueue`.
    case writeQueueFull

    var errorDescription: String? {
        switch self {
        case .noAccessory:
            return "No MFi accessory is connected. Pair the glasses over Bluetooth first."
        case .unsupportedProtocol(let accessories, let advertised):
            let names = accessories.isEmpty
                ? "the connected accessory"
                : accessories.joined(separator: ", ")
            let list = advertised.isEmpty ? "no MFi protocols" : advertised.joined(separator: ", ")
            return "\(names) does not speak either Rokid protocol (advertises: \(list))."
        case .sessionCreationFailed(let protocolString):
            return "iOS refused an EASession for \(protocolString). Either the accessory is not "
                + "paired over MFi, or another app (Rokid's own) holds the session."
        case .streamsUnavailable:
            return "The MFi session opened without usable streams."
        case .notConnected:
            return "No open MFi session."
        case .writeFailed:
            return "The MFi output stream reported an error."
        case .writeQueueFull:
            return "The MFi session is not taking writes as fast as they are sent."
        }
    }
}

/// The real Rokid command transport: Classic Bluetooth over an MFi `EASession`.
///
/// This is the transport the capture says exists. The GATT characteristics in
/// `RokidBLETransport` are a bootstrap only — the command channel is ACL handle 12, L2CAP CID
/// `0x0051` out and `0x0b08` back, carrying RFCOMM, carrying iAP2 `FF 5A` link packets whose
/// payload is a Caps tuple. See `docs/rokid-caps-encoding.md`.
///
/// **What iOS does for us.** MFi identification and authentication are performed by the OS
/// against the Apple Authentication Coprocessor at
/// `/sys/devices/platform/soc/988000.i2c/i2c-2/2-0010` (confirmed present on the device), and iOS
/// adds and strips the iAP2 link envelope, so the session carries bare Caps blobs both ways
/// (``RokidMFIFraming``).
///
/// **What iOS does not do for us.** The glasses' CXR service ignores a session until the client
/// registers on it with a connect message (route `0x1004`), which carries the session's EAP
/// protocol id (``connectedProtocolID``). This class only moves bytes; the layer that composes
/// commands sends that message first. See `docs/rokid-hardware-validation.md`.
///
/// **Threading.** `EASession` streams must be scheduled on a run loop that is being pumped, so
/// the streams live on a dedicated `Thread` inside ``RokidMFIStreamCore``; only whole messages
/// cross back to the main actor. Writes join a ``RokidWriteQueue`` and leave on that thread, as
/// the stream makes room. That core is a plain lock-guarded class rather than an actor
/// because `StreamDelegate` callbacks arrive on that thread and cannot `await`, and it is
/// declared at file scope rather than nested so that it does not inherit this type's
/// `@MainActor` isolation.
@MainActor
final class RokidMFITransport: NSObject, ObservableObject, RokidTransporting {

    /// The protocols to open, in preference order; see ``RokidMFIProtocol/strings``.
    nonisolated static var protocolStrings: [String] { RokidMFIProtocol.strings }

    /// Spelled as a literal rather than through the `EAAccessory` constant so this file does
    /// not depend on how the C symbol is Swift-renamed. The value is the framework's own.
    nonisolated static let didDisconnectNotificationName =
        Notification.Name("EAAccessoryDidDisconnectNotification")

    var onEvent: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    /// Connected accessories that advertise one of ``protocolStrings``, for the pairing UI.
    @Published private(set) var discovered: [(id: String, name: String)] = []

    /// What a write puts on the session. `.rawCaps` is what the glasses accept; `.framed` exists
    /// for the probe (``RokidMFIFraming``). Reads are split by the framing the session opened with.
    var framing: RokidMFIFraming = RokidMFIProtocol.framing

    var isConnected: Bool { core.isOpen }

    /// The protocol string the open session was made for, or `nil` while none is open.
    private(set) var connectedProtocolString: String?

    /// The EAP protocol id of the open session, for the connect message; `nil` while none is open.
    var connectedProtocolID: UInt32? {
        connectedProtocolString.flatMap { RokidMFIProtocol.ids[$0] }
    }

    /// Bytes the open session threw away on the way in because they could not start a message.
    var discardedInboundByteCount: Int { core.discardedInboundByteCount }

    private let core = RokidMFIStreamCore()

    override init() {
        super.init()
        core.onFrame = { [weak self] frame in
            Task { @MainActor in self?.onEvent?(frame) }
        }
        core.onFailed = { [weak self] error in
            Task { @MainActor in self?.onDisconnect?(error) }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect),
            name: Self.didDisconnectNotificationName,
            object: nil
        )
        EAAccessoryManager.shared().registerForLocalNotifications()
        refresh()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Discovery

    /// Re-read the MFi accessory list. MFi has no scan: iOS surfaces an accessory once it is
    /// paired over Bluetooth *and* its protocol appears in `Info.plist` (a local, uncommitted
    /// edit — see ``protocolStrings``).
    func refresh() {
        discovered = EAAccessoryManager.shared().connectedAccessories.compactMap {
            accessory -> (id: String, name: String)? in
            guard !Self.matchingProtocols(for: accessory).isEmpty else { return nil }
            return (id: accessory.serialNumber, name: accessory.name)
        }
    }

    /// The subset of ``protocolStrings`` this accessory advertises, in preference order.
    nonisolated static func matchingProtocols(for accessory: EAAccessory) -> [String] {
        protocolStrings.filter { accessory.protocolStrings.contains($0) }
    }

    // MARK: - RokidTransporting

    func connect() async throws {
        if isConnected { return }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        guard !accessories.isEmpty else { throw RokidMFIError.noAccessory }

        guard let accessory = accessories.first(where: { !Self.matchingProtocols(for: $0).isEmpty }),
              let protocolString = Self.matchingProtocols(for: accessory).first else {
            throw RokidMFIError.unsupportedProtocol(
                accessories: accessories.map(\.name),
                advertised: accessories.flatMap(\.protocolStrings)
            )
        }

        guard let session = EASession(accessory: accessory, forProtocol: protocolString) else {
            throw RokidMFIError.sessionCreationFailed(protocolString: protocolString)
        }
        guard session.inputStream != nil, session.outputStream != nil else {
            throw RokidMFIError.streamsUnavailable
        }

        connectedProtocolString = protocolString
        core.open(session: session, readsRawCaps: framing == .rawCaps)
        refresh()
    }

    func disconnect() {
        core.close()
        connectedProtocolString = nil
        refresh()
    }

    /// Queue one encoded command (a whole link frame, as the encoders build it) for the session.
    ///
    /// Returns once the bytes are queued, not once they are written: the stream takes them as it
    /// makes room. A stream error after that closes the session and arrives on ``onDisconnect``.
    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw RokidMFIError.notConnected }
        try core.enqueue(RokidMFIPayload.payload(for: bytes, framing: framing))
    }

    // MARK: - Notifications

    @objc private func accessoryDidDisconnect() {
        refresh()
        guard isConnected, discovered.isEmpty else { return }
        core.close()
        connectedProtocolString = nil
        onDisconnect?(nil)
    }
}

// MARK: - Streams

/// Owns the `EASession` and its streams on their own run-loop thread.
///
/// Every member is called either under `lock` or from the stream thread. `onFrame`/`onFailed`
/// are assigned once, before ``open(session:readsRawCaps:)``, and never mutated afterwards.
/// Marked `@unchecked Sendable` because the lock, not the compiler, keeps it safe: the transport
/// queues writes from the main actor, and the stream thread drains them.
private final class RokidMFIStreamCore: NSObject, StreamDelegate, @unchecked Sendable {

    var onFrame: (([UInt8]) -> Void)?
    var onFailed: ((Error?) -> Void)?

    private let lock = NSLock()
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?
    private var thread: Thread?
    /// The stream thread's run loop, once it is running, so a queued write can wake it.
    private var runLoop: CFRunLoop?
    private var frameDrain = RokidFrameDrain()
    private var capsDrain = RokidCapsDrain()
    private var readsRawCaps = true
    private var writes = RokidWriteQueue()
    private var closing = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil && input != nil && output != nil && !closing
    }

    var discardedInboundByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capsDrain.discardedByteCount
    }

    /// - Parameter readsRawCaps: split reads into bare Caps blobs (an MFi session) rather than
    ///   `FF 5A` link frames. Fixed for the life of the session.
    func open(session: EASession, readsRawCaps: Bool) {
        lock.lock()
        self.session = session
        self.input = session.inputStream
        self.output = session.outputStream
        self.closing = false
        self.readsRawCaps = readsRawCaps
        self.frameDrain.reset()
        self.capsDrain = RokidCapsDrain()
        self.writes.removeAll()
        self.runLoop = nil
        lock.unlock()

        let thread = Thread { [weak self] in self?.runStreamLoop() }
        thread.name = "RokidMFITransport.streams"
        thread.stackSize = 512 * 1024
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    /// Queue `bytes` whole and wake the stream thread to send what the stream has room for.
    func enqueue(_ bytes: [UInt8]) throws {
        lock.lock()
        guard output != nil, !closing else {
            lock.unlock()
            throw RokidMFIError.notConnected
        }
        guard writes.enqueue(bytes) else {
            lock.unlock()
            throw RokidMFIError.writeQueueFull
        }
        let loop = runLoop
        lock.unlock()

        // Before the thread's run loop exists there is nothing to wake: opening the output
        // stream reports space, and that event drains whatever was queued meanwhile.
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.drainWrites()
        }
        CFRunLoopWakeUp(loop)
    }

    /// Tear down without notifying — the caller decides whether this close is worth reporting.
    func close() {
        lock.lock()
        closing = true
        input?.close()
        output?.close()
        session = nil
        input = nil
        output = nil
        writes.removeAll()
        lock.unlock()
    }

    private func isClosing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closing
    }

    /// Pump the run loop the streams are scheduled on until ``close()``.
    private func runStreamLoop() {
        lock.lock()
        let input = self.input
        let output = self.output
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()
        guard let input, let output else { return }

        input.delegate = self
        output.delegate = self
        input.schedule(in: .current, forMode: .default)
        output.schedule(in: .current, forMode: .default)
        input.open()
        output.open()

        while !isClosing() {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
        }

        input.close()
        output.close()
        input.remove(from: .current, forMode: .default)
        output.remove(from: .current, forMode: .default)
        lock.lock()
        runLoop = nil
        lock.unlock()
    }

    /// Stream thread only. Sends queued bytes until the queue empties or the stream is full; a
    /// full stream reports space again later, which calls this again.
    private func drainWrites() {
        lock.lock()
        guard let stream = output, !closing else {
            lock.unlock()
            return
        }
        // Holding the lock across the writes is deliberate: they never block, because each one
        // is made only while the stream reports space, and it keeps `close()` from clearing the
        // queue in the middle of a write.
        let outcome = writes.drain { base, count in
            stream.hasSpaceAvailable ? stream.write(base, maxLength: count) : 0
        }
        lock.unlock()

        if outcome == .failed {
            failed(stream.streamError ?? RokidMFIError.writeFailed)
        }
    }

    private func readAvailableBytes() {
        lock.lock()
        let stream = input
        lock.unlock()
        guard let stream else { return }

        var chunk = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&chunk, maxLength: chunk.count)
            guard read > 0 else { break }

            let messages: [[UInt8]]
            lock.lock()
            let bytes = Array(chunk[0..<read])
            messages = readsRawCaps ? capsDrain.append(bytes) : frameDrain.append(bytes)
            lock.unlock()

            for message in messages { onFrame?(message) }
        }
    }

    /// A stream failure is the one close worth reporting: the session died underneath us.
    private func failed(_ error: Error?) {
        close()
        onFailed?(error)
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        // `Stream.Event` is an OptionSet, not an enum: cases can arrive combined, so no
        // `switch` over it can ever be exhaustive and the enum-only wildcard arm does not
        // compile. Worse, equality-matched switch cases would let a combined
        // `hasBytesAvailable | endEncountered` fall through as if it were plain data, so
        // the two terminal events are tested first with `contains`.
        if eventCode.contains(.errorOccurred) {
            failed(stream.streamError)
            return
        }
        if eventCode.contains(.endEncountered) {
            failed(nil)
            return
        }
        if eventCode.contains(.hasBytesAvailable) {
            readAvailableBytes()
        }
        if eventCode.contains(.hasSpaceAvailable) {
            drainWrites()
        }
    }
}
#endif
