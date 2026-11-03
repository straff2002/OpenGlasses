import Combine
import Foundation

/// The SDK implementations do not compile into the phone-only product.
@MainActor
enum GlassesBackendFactory {
    static func camera() -> any GlassesCameraBackend {
        #if AVENKIN_PHONE_ONLY
        return UnsupportedGlassesCameraBackend()
        #else
        return MetaCameraBackend()
        #endif
    }

    static func link() -> any GlassesLinkSource {
        #if AVENKIN_PHONE_ONLY
        return UnsupportedGlassesLinkSource()
        #else
        return WearablesGlassesLinkSource()
        #endif
    }
}

@MainActor
final class UnsupportedGlassesCameraBackend: GlassesCameraBackend {
    let capabilities = CameraCapabilities.unavailable
    let events = PassthroughSubject<CameraBackendEvent, Never>()
    var permissionGranted = false
    func isReady(configuringIfNeeded: Bool) -> Bool { false }
    func ensurePermission() async throws { throw unavailable }
    func capturePhoto() async throws -> Data { throw unavailable }
    func startStreaming() async throws { throw unavailable }
    func stopStreaming() async {}
    func tearDown() async {}
    private var unavailable: WearablesBootstrap.Unavailable {
        .init(reason: GlassesSupportPolicy.unavailableReason())
    }
}

@MainActor
final class UnsupportedGlassesLinkSource: GlassesLinkSource {
    func activate() -> Bool { false }
    var registration: GlassesRegistration { GlassesRegistration(stateRaw: 0) }
    var devices: [String] { [] }
    func deviceName(for id: String) -> String? { nil }
    func observeRegistration(_ onChange: @escaping @MainActor @Sendable (GlassesRegistration) -> Void) -> any GlassesLinkObservation {
        InactiveGlassesObservation()
    }
    func observeDevices(_ onChange: @escaping @MainActor @Sendable ([String]) -> Void) -> any GlassesLinkObservation {
        InactiveGlassesObservation()
    }
    func observeDeviceState(for id: String,
                            _ onChange: @escaping @MainActor @Sendable (GlassesDeviceState) -> Void) -> (any GlassesLinkObservation)? { nil }
}

@MainActor
private final class InactiveGlassesObservation: GlassesLinkObservation {
    func cancel() {}
}

@MainActor
final class UnsupportedGlassesDisplayBackend: GlassesDisplayBackend {
    var isAvailable: Bool { false }
    var onItemSelected: ((String) -> Void)?
    var onTransportError: ((Error) -> Void)?
    func showContent(title: String?, body: String, icon: HUDIcon) async throws {}
    func send(screen: HUDScreen) async throws {}
    func clear() async throws {}
    func shutdown() async {}
    func resetAfterError() {}
}
