import Foundation

/// Transport seam for the Rokid backend: real CoreBluetooth (`RokidBLETransport`) in
/// production, a command-recording mock in tests. Rokid glasses are a single peripheral
/// (one micro-display), unlike the EVEN G2's two lenses.
@MainActor
protocol RokidTransporting: AnyObject {
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    /// Write one encoded command to the glasses' write characteristic.
    func send(_ bytes: [UInt8]) async throws
    /// Notify-characteristic traffic (responses, gesture events).
    var onEvent: (([UInt8]) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
}

/// Plan AH — the third renderer: `HUDScreen`/content → `[RokidCommand]` → Caps frames →
/// transport. Everything up to the transport is deterministic and tested against a mock.
///
/// The encoding is no longer reconstructed guesswork: `RokidCapsCodec` and
/// `RokidIAP2Packet` reproduce 3,215 of 3,216 captured device frames byte for byte (see
/// `docs/rokid-caps-encoding.md`). What is still unvalidated on hardware is the *transport*,
/// because the captured command channel is MFi/iAP2 over Classic Bluetooth, not GATT — the
/// BLE characteristics are a bootstrap. Two transports therefore exist behind
/// ``RokidTransporting``; see ``Config/rokidUsesMFI`` to pick one.
@MainActor
final class RokidDisplayBackend: GlassesDisplayBackend {

    var onItemSelected: ((String) -> Void)?
    var onTransportError: ((Error) -> Void)?

    private let transport: RokidTransporting
    /// Item ids of the last interactive screen, in rendered (numbered) order — a future
    /// temple-gesture / voice "select N" event resolves through this.
    private(set) var currentItemIds: [String] = []

    /// Per-connection frame counter. The glasses echo this in responses, so it advances
    /// once per sent frame rather than restarting per screen.
    private var sequence: UInt32 = 0
    /// Origin for frame timestamps — only monotonicity matters to the glasses.
    private let clockOrigin = DispatchTime.now()

    init(transport: RokidTransporting? = nil) {
        let resolved: RokidTransporting
        if let transport {
            resolved = transport
        } else if Config.rokidUsesMFI {
            resolved = RokidMFITransport()
        } else {
            resolved = RokidBLETransport()
        }
        self.transport = resolved
        self.transport.onDisconnect = { [weak self] error in
            self?.onTransportError?(error ?? GlassesDisplayError.sessionUnavailable)
        }
        self.transport.onEvent = { _ in
            // Gesture/response format is unknown until capture logs exist (Phase 1);
            // events are surfaced for logging only. Selection arrives via
            // `selectItem(index:)` (voice grammar / tests), same as the EVEN backend.
        }
    }

    // MARK: - GlassesDisplayBackend

    var isAvailable: Bool { Config.rokidPairingConfigured }

    func showContent(title: String?, body: String, icon: HUDIcon) async throws {
        try await push(RokidScreenRenderer.renderContent(title: title, body: body, icon: icon))
        currentItemIds = []
    }

    func send(screen: HUDScreen) async throws {
        try await push(RokidScreenRenderer.renderScreen(screen))
        currentItemIds = screen.items.map(\.id)
    }

    func clear() async throws {
        try await push(RokidScreenRenderer.clearCommands())
        currentItemIds = []
    }

    func shutdown() async {
        transport.disconnect()
        currentItemIds = []
    }

    func resetAfterError() {
        transport.disconnect()
        currentItemIds = []
    }

    /// Select the N-th rendered item (1-based, matching the numbered labels). Voice
    /// ("one", "two") and future gesture parsing both land here.
    func selectItem(index: Int) {
        guard index >= 1, index <= currentItemIds.count else { return }
        onItemSelected?(currentItemIds[index - 1])
    }

    // MARK: - Pipeline

    private func push(_ commands: [RokidCommand]) async throws {
        if !transport.isConnected {
            try await transport.connect()
        }
        for command in commands {
            sequence &+= 1
            let elapsed = DispatchTime.now().uptimeNanoseconds &- clockOrigin.uptimeNanoseconds
            try await transport.send(
                command.encoded(
                    sequence: sequence,
                    timestampMicroseconds: UInt32(truncatingIfNeeded: elapsed / 1_000)
                )
            )
        }
    }
}

// MARK: - Config

extension Config {
    /// Persisted CoreBluetooth peripheral identifier for the paired Rokid glasses.
    static var rokidPeripheralID: String? {
        get { UserDefaults.standard.string(forKey: "rokidPeripheralID") }
        set { UserDefaults.standard.set(newValue, forKey: "rokidPeripheralID") }
    }

    static var rokidPairingConfigured: Bool { rokidPeripheralID != nil }

    /// Which transport carries Rokid commands.
    ///
    /// `true` opens an MFi `EASession` (`RokidMFITransport`) — the channel the capture
    /// actually shows: Classic Bluetooth, ACL handle 12, L2CAP CID `0x0051` out and `0x0b08`
    /// back, carrying RFCOMM and iAP2 `FF 5A` frames. `false` uses the GATT bootstrap
    /// (`RokidBLETransport`), which can reach the discovery characteristics but is not where
    /// commands travel.
    ///
    /// Defaults to `false` so no existing behaviour changes silently. Set it at launch, from
    /// the debugger, or from a test to run the hardware spike:
    /// `UserDefaults.standard.set(true, forKey: "rokidUsesMFI")`.
    static var rokidUsesMFI: Bool {
        get { UserDefaults.standard.bool(forKey: "rokidUsesMFI") }
        set { UserDefaults.standard.set(newValue, forKey: "rokidUsesMFI") }
    }
}
