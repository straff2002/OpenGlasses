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

    var errorDescription: String? {
        switch self {
        case .noAccessory:
            return "No MFi accessory is connected. Pair the glasses over Bluetooth first."
        case .unsupportedProtocol(let accessories, let advertised):
            let names = accessories.isEmpty
                ? "the connected accessory"
                : accessories.joined(separator: ", ")
            let list = advertised.isEmpty ? "no MFi protocols" : advertised.joined(separator: ", ")
            return "\(names) does not speak com.rokid.aiglasses (advertises: \(list))."
        case .sessionCreationFailed(let protocolString):
            return "iOS refused an EASession for \(protocolString). Either the accessory is not "
                + "paired over MFi, or another app (Rokid's own) holds the session."
        case .streamsUnavailable:
            return "The MFi session opened without usable streams."
        case .notConnected:
            return "No open MFi session."
        case .writeFailed:
            return "The MFi output stream accepted no bytes."
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
/// **What iOS does for us.** There is no app-level handshake to reverse: the captured session
/// goes from RFCOMM modem text (`+CIEV: 5,3`) straight into a complete command. MFi
/// identification and authentication are performed by the OS against the Apple
/// Authentication Coprocessor at `/sys/devices/platform/soc/988000.i2c/i2c-2/2-0010`
/// (confirmed present on the device), so this class only has to open a session and move bytes.
///
/// **Threading.** `EASession` streams must be scheduled on a run loop that is being pumped, so
/// the streams live on a dedicated `Thread` inside ``RokidMFIStreamCore``; only whole frames
/// cross back to the main actor. That core is a plain lock-guarded class rather than an actor
/// because `StreamDelegate` callbacks arrive on that thread and cannot `await`, and it is
/// declared at file scope rather than nested so that it does not inherit this type's
/// `@MainActor` isolation.
@MainActor
final class RokidMFITransport: NSObject, ObservableObject, RokidTransporting {

    /// The two `mfi.eap` names in the glasses' `cxr-service.json`, in preference order:
    /// `com.rokid.aiglasses` (id 194) and `com.rokid.global.aiglasses` (id 195).
    ///
    /// **Not declared in the committed `Info.plist`, on purpose.** iOS only opens an `EASession`
    /// for a protocol listed under `UISupportedExternalAccessoryProtocols`, and App Review rejects
    /// a build that lists an MFi protocol unless the accessory maker has registered that app with
    /// Apple's MFi program. Registration is per app: Rokid is an MFi licensee and registered its own
    /// app, but not this one. Add both strings to `Info.plist` locally for a hardware spike and never
    /// commit them; `RokidAccessoryProtocolGuardTests` fails if they land.
    nonisolated static let protocolStrings = [
        "com.rokid.aiglasses",
        "com.rokid.global.aiglasses",
    ]

    /// Spelled as a literal rather than through the `EAAccessory` constant so this file does
    /// not depend on how the C symbol is Swift-renamed. The value is the framework's own.
    nonisolated static let didDisconnectNotificationName =
        Notification.Name("EAAccessoryDidDisconnectNotification")

    var onEvent: (([UInt8]) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    /// Connected accessories that advertise one of ``protocolStrings``, for the pairing UI.
    @Published private(set) var discovered: [(id: String, name: String)] = []

    /// Set from a hardware experiment — see ``RokidMFIFraming``.
    var framing: RokidMFIFraming = .framed

    var isConnected: Bool { core.isOpen }

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

        core.open(session: session)
        refresh()
    }

    func disconnect() {
        core.close()
        refresh()
    }

    func send(_ bytes: [UInt8]) async throws {
        guard isConnected else { throw RokidMFIError.notConnected }
        try core.write(RokidMFIPayload.payload(for: bytes, framing: framing))
    }

    // MARK: - Notifications

    @objc private func accessoryDidDisconnect() {
        refresh()
        guard isConnected, discovered.isEmpty else { return }
        core.close()
        onDisconnect?(nil)
    }
}

// MARK: - Streams

/// Owns the `EASession` and its streams on their own run-loop thread.
///
/// Every member is called either under `lock` or from the stream thread. `onFrame`/`onFailed`
/// are assigned once, before ``open(session:)``, and never mutated afterwards.
private final class RokidMFIStreamCore: NSObject, StreamDelegate {

    var onFrame: (([UInt8]) -> Void)?
    var onFailed: ((Error?) -> Void)?

    private let lock = NSLock()
    private var session: EASession?
    private var input: InputStream?
    private var output: OutputStream?
    private var thread: Thread?
    private var drain = RokidFrameDrain()
    private var closing = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil && input != nil && output != nil && !closing
    }

    func open(session: EASession) {
        lock.lock()
        self.session = session
        self.input = session.inputStream
        self.output = session.outputStream
        self.closing = false
        self.drain.reset()
        lock.unlock()

        let thread = Thread { [weak self] in self?.runStreamLoop() }
        thread.name = "RokidMFITransport.streams"
        thread.stackSize = 512 * 1024
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    func write(_ bytes: [UInt8]) throws {
        lock.lock()
        let stream = output
        lock.unlock()
        guard let stream else { throw RokidMFIError.notConnected }

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return stream.write(base.advanced(by: offset), maxLength: bytes.count - offset)
            }
            guard written > 0 else { throw RokidMFIError.writeFailed }
            offset += written
        }
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

            let frames: [[UInt8]]
            lock.lock()
            frames = drain.append(Array(chunk[0..<read]))
            lock.unlock()

            for frame in frames { onFrame?(frame) }
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
    }
}
