import Combine
import UIKit

/// Plan AH P2 — the Rokid camera seam.
///
/// Companion to Plan AH's display backend (`RokidDisplayBackend`) and built against the same
/// seam shape as Plan CQ P1's `MetaCameraBackend`: a backend owns the *device* and `CameraService`
/// owns everything backend-neutral. The two are deliberately independent — a Rokid HUD with a
/// Meta camera, or the reverse, are working hybrids by construction.
///
/// The honesty rule is the one the display backend already follows: declare what the hardware
/// can do, ship the adapter dark where the wire is not yet recovered, and let the app's existing
/// gates turn that into something a user can read. See `docs/rokid-rv101.md`.

/// Which device family serves the camera (Plan AH P2). Camera only — display and audio run on
/// their own services.
enum CameraBackendChoice: String, CaseIterable {
    case metaRayBan
    case rokidRV101

    var displayName: String {
        switch self {
        case .metaRayBan: return "Ray-Ban Meta"
        case .rokidRV101: return "Rokid RV101"
        }
    }
}

extension Config {
    static var cameraBackend: CameraBackendChoice {
        get {
            UserDefaults.standard.string(forKey: "cameraBackend")
                .flatMap(CameraBackendChoice.init(rawValue:)) ?? .metaRayBan
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "cameraBackend") }
    }
}

/// How still bytes move between the app and Rokid glasses.
///
/// The glasses' high-bandwidth camera path is **not** BLE — BLE carries control only, and a
/// single still is far too large for a GATT write. Real captures travel the glasses' network
/// path (Rokid `Med` capture then a fetch, or an `Ai`/`ARTC` frame). This protocol is the seam
/// so the honest stub and a future real transport swap without touching `RokidCameraBackend`.
@MainActor
protocol RokidCameraTransporting: AnyObject {
    var isConnected: Bool { get }
    func connect() async throws
    func disconnect()
    /// Request one still and await its JPEG bytes. Ships dark — sends the `Med` capture and
    /// fetches the result over the glasses' network path.
    func captureStill() async throws -> Data
    var onDisconnect: ((Error?) -> Void)? { get set }
}

/// The production transport placeholder. Every operation reports its honest unavailability so
/// a Rokid-selected camera degrades to the phone-camera fallback instead of pretending.
@MainActor
final class RokidCameraTransport: RokidCameraTransporting {
    var isConnected: Bool { false }
    var onDisconnect: ((Error?) -> Void)?
    func connect() async throws { throw RokidCameraError.notConnected }
    func disconnect() {}
    func captureStill() async throws -> Data { throw RokidCameraError.stillUnavailable }
}

/// Plan AH P2 — the Rokid RV101 camera, behind `GlassesCameraBackend`.
///
/// Declares the hardware truth the rest of the app is built to consume: the glasses *can*
/// capture stills (fetched over the network, so several seconds), but do **not** stream live
/// frames into the app today — BLE cannot carry video, and a real frame path is a separate
/// transport that awaits hardware. `CameraFeatureGate` turns that into "Live Preview needs a
/// live camera feed …" and "Captures … take several seconds", while still captures degrade to
/// the iPhone camera until the transport lands.
@MainActor
final class RokidCameraBackend: GlassesCameraBackend {

    let capabilities = CameraCapabilities(
        liveFrames: false,
        stillCapture: true,
        stillLatency: .seconds,
        concurrentWithMic: true,
        hardwareEvents: false
    )

    let events = PassthroughSubject<CameraBackendEvent, Never>()

    private let transport: RokidCameraTransporting
    private var connectTask: Task<Void, Never>?

    var permissionGranted: Bool

    init(transport: RokidCameraTransporting, permissionGranted: Bool = false) {
        self.transport = transport
        self.permissionGranted = permissionGranted
        transport.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.events.send(.frame(nil, fresh: false))
            self.events.send(.status(.stopped))
            self.events.send(.transientNotice("Rokid glasses disconnected."))
        }
    }

    func isReady(configuringIfNeeded: Bool) -> Bool {
        if transport.isConnected { return true }
        guard configuringIfNeeded else { return false }
        connectTask = Task { [weak self] in _ = try? await self?.transport.connect() }
        return false
    }

    func ensurePermission() async throws {
        guard permissionGranted else { throw RokidCameraError.permissionNotGranted }
    }

    func capturePhoto() async throws -> Data {
        guard transport.isConnected else { throw RokidCameraError.notConnected }
        return try await transport.captureStill()
    }

    func startStreaming() async throws {
        // No live frames, by declaration. Conformance only; `CameraFeatureGate` keeps
        // live-frame features off this backend, and this throws for anything that ignores it.
        throw RokidCameraError.liveFramesUnavailable
    }

    func stopStreaming() async {
        events.send(.status(.stopped))
        events.send(.frame(nil, fresh: false))
    }

    func tearDown() async {
        connectTask?.cancel()
        connectTask = nil
        transport.disconnect()
    }
}

/// Plan AH P2 — honest failures for the dark transport edge.
enum RokidCameraError: Error, Equatable, LocalizedError {
    case notConnected
    case permissionNotGranted
    case liveFramesUnavailable
    case stillUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Rokid glasses are not connected."
        case .permissionNotGranted: return "Camera permission for the Rokid glasses has not been granted."
        case .liveFramesUnavailable: return "Rokid glasses do not stream live frames to the app."
        case .stillUnavailable: return "The Rokid glasses could not deliver a photo."
        }
    }
}
