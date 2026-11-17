import Foundation

/// Central gate for features that turn untrusted QR/deep-link input into a network request.
/// Production is enabled only through `BoundedHTTPClient`; the refusal case remains injectable so
/// containment behavior stays testable and can be restored independently if a regression is found.
enum UntrustedNetworkFeaturePolicy {
    enum BuildFlavor {
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

    enum Feature: CaseIterable {
        case qrContextFetch
        case skillPackDeepLinkFetch
        /// `install-addon` (Plan GF): one small add-on file, fetched only after the wearer says yes.
        case addOnDeepLinkFetch
    }

    enum Decision: Equatable {
        case allowHardenedFetch
        case refuseUntilHardenedClient

        var allowsRequest: Bool {
            self == .allowHardenedFetch
        }
    }

    static func decision(for feature: Feature, build: BuildFlavor) -> Decision {
        _ = feature
        _ = build
        return .allowHardenedFetch
    }

    static func currentDecision(for feature: Feature) -> Decision {
        decision(for: feature, build: .current)
    }

    static let unavailableMessage =
        "Remote content loading is unavailable in this build until its secure download path is ready."
}
