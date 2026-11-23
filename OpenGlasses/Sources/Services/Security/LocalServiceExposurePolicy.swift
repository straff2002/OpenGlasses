import Foundation

/// Build boundary for the legacy cleartext HTTP listener.
///
/// The current MCP Glasses transport has bearer authentication but no transport confidentiality.
/// It may remain available in a Debug build for the existing phone-to-Mac development loop, but a
/// production build must refuse to create the listener. This is only containment: it does not
/// provide TLS, pairing, replay protection, or scoped authorization. (The web mirror of the lens
/// was the other such listener until it was retired on 2026-11-23.)
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
        _ = service // Every legacy listener shares the same build boundary.
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
            return ["mcpServerEnabled"]
        }
    }

    func clearPersistedOptIns(defaults: UserDefaults = .standard) {
        for key in persistedOptInKeysToClear {
            defaults.removeObject(forKey: key)
        }
    }
}
