import Foundation
import Network

/// What a legacy cleartext LAN service asks for when it wants to bind a socket.
///
/// The two legacy servers (`MCPGlassesServer`, `WebHUDMirrorServer`) no longer construct an
/// `NWListener` themselves; they describe the listener they want and hand the description to a
/// ``LocalListenerFactory``. That indirection is the seam ``LocalServiceExposureCompositionTests``
/// uses to prove — at the composition level, not only in the pure policy — that a
/// Release-flavoured build never reaches listener construction at all.
struct LocalListenerRequest: Equatable {
    let service: LocalServiceExposurePolicy.Service
    let port: UInt16
    let allowsLocalEndpointReuse: Bool

    init(service: LocalServiceExposurePolicy.Service, port: UInt16, allowsLocalEndpointReuse: Bool = true) {
        self.service = service
        self.port = port
        self.allowsLocalEndpointReuse = allowsLocalEndpointReuse
    }
}

/// A bound listener plus the build marker naming the transport that produced it.
///
/// The marker is deliberately a literal that only exists in a build which can actually open the
/// legacy transport, so `Scripts/check-release-listener-strings.sh` can assert its absence from a
/// Release artefact. It is carried on the handle rather than parked in an unused constant so the
/// literal is genuinely referenced by the code path that opens the socket.
struct LocalListenerHandle {
    let listener: NWListener
    let buildMarker: String
}

/// Refusal raised by the production factory in a build that must not open the legacy transport.
struct LocalListenerRefusal: Error, LocalizedError, Equatable {
    let marker: String
    let service: LocalServiceExposurePolicy.Service

    var errorDescription: String? { marker }
}

typealias LocalListenerFactory = (LocalListenerRequest) throws -> LocalListenerHandle

/// Supplies the production listener factory for the legacy cleartext services.
///
/// This is defence in depth behind ``LocalServiceExposurePolicy``, not a replacement for it: the
/// policy check still runs first in each server. Compiling the socket-opening branch out of a
/// Release build means that even a bypassed policy check has nothing left to call, and it makes
/// the containment inspectable in the shipped binary rather than only in source.
enum LocalListenerProvider {

    /// Present in a Release artefact; asserted present by the artefact check as a positive control
    /// (so a check that finds nothing cannot be mistaken for a passing check).
    static let releaseRefusalMarker = "release-refuses-legacy-cleartext-listener"

#if DEBUG
    /// Per-service markers for the permitted development LAN transport. Asserted ABSENT from a
    /// Release artefact.
    static func debugBuildMarker(for service: LocalServiceExposurePolicy.Service) -> String {
        switch service {
        case .mcpGlasses: return "mcp-glasses-legacy-cleartext-listener-debug-only"
        case .webHUDMirror: return "web-hud-mirror-legacy-cleartext-listener-debug-only"
        }
    }
#endif

    static let production: LocalListenerFactory = { request in
#if DEBUG
        guard let port = NWEndpoint.Port(rawValue: request.port) else {
            throw LocalListenerRefusal(marker: "invalid-port", service: request.service)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = request.allowsLocalEndpointReuse
        return LocalListenerHandle(listener: try NWListener(using: parameters, on: port),
                                   buildMarker: debugBuildMarker(for: request.service))
#else
        throw LocalListenerRefusal(marker: releaseRefusalMarker, service: request.service)
#endif
    }
}

/// Published availability of a legacy cleartext LAN service.
///
/// `unavailableInProduction` is a distinct state rather than "stopped", so a Release build is
/// observably refusing rather than merely idle, and a test can tell the two apart.
enum LocalServiceAvailability: Equatable {
    case stopped
    case running
    case unavailableInProduction
}
