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

/// Plan AH — the third renderer: `HUDScreen`/content → `[RokidCommand]` → JSON bytes →
/// BLE. Everything up to the transport is deterministic and tested against a mock; the
/// BLE edge ships dark until hardware validates the community protocol reconstruction
/// (Caps framing + GATT UUIDs + any app-level handshake).
@MainActor
final class RokidDisplayBackend: GlassesDisplayBackend {

    var onItemSelected: ((String) -> Void)?
    var onTransportError: ((Error) -> Void)?

    private let transport: RokidTransporting
    /// Item ids of the last interactive screen, in rendered (numbered) order — a future
    /// temple-gesture / voice "select N" event resolves through this.
    private(set) var currentItemIds: [String] = []

    init(transport: RokidTransporting? = nil) {
        self.transport = transport ?? RokidBLETransport()
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
            try await transport.send(command.encoded())
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
}
