import Foundation

/// Build boundary for the two legacy cleartext HTTP listeners.
///
/// The current MCP Glasses and Web HUD transports have bearer authentication but no transport
/// confidentiality. They may remain available in a Debug build for the existing phone-to-Mac
/// development loop, but a production build must refuse to create either listener. This is only
/// containment: it does not provide TLS, pairing, replay protection, or scoped authorization.
struct LocalServiceExposurePolicy: Equatable {
    enum BuildFlavor: Equatable {
        case debug
        case release

        static var current: Self {
#if DEBUG
            .debug
#else
            .release
#endif
        }
    }

    enum Service: CaseIterable, Equatable {
        case mcpGlasses
        case webHUDMirror
    }

    enum Decision: Equatable {
        /// Existing development transport. It is intentionally named as legacy cleartext so it
        /// cannot be mistaken for the future paired/TLS transport.
        case allowLegacyCleartextDevelopmentLAN
        case refuseProductionCleartext

        var permitsListener: Bool {
            self == .allowLegacyCleartextDevelopmentLAN
        }
    }

    let buildFlavor: BuildFlavor

    static let current = LocalServiceExposurePolicy(buildFlavor: .current)

    func decision(for service: Service) -> Decision {
        _ = service // Both legacy listeners share the same build boundary.
        switch buildFlavor {
        case .debug:
            return .allowLegacyCleartextDevelopmentLAN
        case .release:
            return .refuseProductionCleartext
        }
    }

    func permitsListener(for service: Service) -> Bool {
        decision(for: service).permitsListener
    }

    /// Preference keys retired by the production build. The listener decision does not rely on
    /// this cleanup; removing them prevents a Debug opt-in restored from backup from looking active
    /// in production UI and makes migration behavior explicit and testable.
    var persistedOptInKeysToClear: [String] {
        switch buildFlavor {
        case .debug:
            return []
        case .release:
            return ["mcpServerEnabled", "hudMirrorEnabled"]
        }
    }

    func clearPersistedOptIns(defaults: UserDefaults = .standard) {
        for key in persistedOptInKeysToClear {
            defaults.removeObject(forKey: key)
        }
    }
}
