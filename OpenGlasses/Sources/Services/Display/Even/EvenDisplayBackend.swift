import Foundation

/// Transport seam for the EVEN backend: real CoreBluetooth (`EvenBLETransport`) in
/// production, a packet-recording mock in tests. Mirrored frames go to both lenses
/// (L/R policy decided: same frame both sides — the G2 is a binocular display).
@MainActor
protocol EvenTransporting: AnyObject {
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    /// Write one encoded render packet to the rendering characteristic of both lenses.
    func sendRenderPacket(_ bytes: [UInt8]) async throws
    /// Notify-characteristic traffic (responses, temple-gesture events).
    var onEvent: (([UInt8]) -> Void)? { get set }
    var onDisconnect: ((Error?) -> Void)? { get set }
}

/// Plan AH — the first true second renderer: `HUDScreen`/content → `EvenFrame` →
/// framed packets → BLE. Everything up to the transport is deterministic and tested
/// against a mock; the BLE edge ships dark until hardware validates the community
/// protocol reconstruction.
@MainActor
final class EvenDisplayBackend: GlassesDisplayBackend {

    var onItemSelected: ((String) -> Void)?
    var onTransportError: ((Error) -> Void)?

    private let transport: EvenTransporting
    private var sequence: UInt8 = 0
    /// Item ids of the last interactive screen, in rendered (numbered) order — a future
    /// temple-gesture "select N" event resolves through this.
    private(set) var currentItemIds: [String] = []

    /// Render-payload service id — placeholder pending capture-log validation (the
    /// packet layer, not this constant, is what the tests pin down).
    static let renderServiceId: UInt16 = 0x0001

    init(transport: EvenTransporting? = nil) {
        self.transport = transport ?? EvenBLETransport()
        self.transport.onDisconnect = { [weak self] error in
            self?.onTransportError?(error ?? GlassesDisplayError.sessionUnavailable)
        }
        self.transport.onEvent = { _ in
            // Temple-gesture format is unknown until capture logs exist (Phase 2);
            // events are surfaced for logging only. Selection meanwhile arrives via
            // `selectItem(index:)` (voice grammar / tests).
        }
    }

    // MARK: - GlassesDisplayBackend

    var isAvailable: Bool { Config.evenPairingConfigured }

    func showContent(title: String?, body: String, icon: HUDIcon) async throws {
        try await push(EvenScreenRenderer.render(title: title, body: body, icon: icon))
        currentItemIds = []
    }

    func send(screen: HUDScreen) async throws {
        try await push(EvenScreenRenderer.render(screen: screen))
        currentItemIds = screen.items.map(\.id)
    }

    func clear() async throws {
        try await push(EvenScreenRenderer.clearFrame())
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
    /// ("one", "two") and future temple-gesture parsing both land here.
    func selectItem(index: Int) {
        guard index >= 1, index <= currentItemIds.count else { return }
        onItemSelected?(currentItemIds[index - 1])
    }

    // MARK: - Pipeline

    private func push(_ frame: EvenFrame) async throws {
        if !transport.isConnected {
            try await transport.connect()
        }
        sequence &+= 1
        let packets = EvenPacket.fragments(type: .command, sequence: sequence,
                                           service: Self.renderServiceId,
                                           payload: frame.payloadBytes)
        for packet in packets {
            try await transport.sendRenderPacket(packet.encoded())
        }
    }
}

// MARK: - Config

/// Which device family renders the HUD (Plan AH). Display only — camera/audio run on
/// their own services, so Meta camera + EVEN HUD is a working hybrid by construction.
enum DisplayBackendChoice: String, CaseIterable {
    case metaRayBan
    case evenG2

    var displayName: String {
        switch self {
        case .metaRayBan: return "Ray-Ban Display"
        case .evenG2: return "EVEN G2"
        }
    }
}

extension Config {
    static var displayBackend: DisplayBackendChoice {
        get {
            UserDefaults.standard.string(forKey: "displayBackend")
                .flatMap(DisplayBackendChoice.init(rawValue:)) ?? .metaRayBan
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "displayBackend") }
    }

    /// Persisted CoreBluetooth peripheral identifiers — left/right lenses are separate
    /// peripherals and both are paired. Single-lens degraded state: right may be nil.
    static var evenLeftPeripheralID: String? {
        get { UserDefaults.standard.string(forKey: "evenLeftPeripheralID") }
        set { UserDefaults.standard.set(newValue, forKey: "evenLeftPeripheralID") }
    }

    static var evenRightPeripheralID: String? {
        get { UserDefaults.standard.string(forKey: "evenRightPeripheralID") }
        set { UserDefaults.standard.set(newValue, forKey: "evenRightPeripheralID") }
    }

    static var evenPairingConfigured: Bool { evenLeftPeripheralID != nil }
}
