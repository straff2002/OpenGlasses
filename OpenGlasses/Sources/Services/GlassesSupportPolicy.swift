import Foundation

/// A compile-time product boundary. Installation receipts never decide feature availability.
enum AppBuildVariant: String {
    case phoneOnly = "phone-only"
    case glassesBeta = "glasses-beta"

    static var current: Self {
        #if AVENKIN_PHONE_ONLY
        return .phoneOnly
        #else
        return .glassesBeta
        #endif
    }
}

enum GlassesSupportPolicy {
    enum Verdict: Equatable { case supported, notInThisVersion }

    static func verdict(variant: AppBuildVariant) -> Verdict {
        variant == .phoneOnly ? .notInThisVersion : .supported
    }

    static func unavailableReason(appName: String = RegistrationFlow.appName) -> String {
        "Smart glasses aren't supported in this version of \(appName)."
    }

    static var current: Verdict {
        // Even a test/developer override cannot add hardware support to the phone product.
        guard AppBuildVariant.current != .phoneOnly else { return .notInThisVersion }
        return overrideForTesting ?? .supported
    }
    static var isSupported: Bool { current == .supported }
    static var reportLine: String {
        "Build variant: " + AppBuildVariant.current.rawValue + " · Glasses: "
            + (isSupported ? "offered by this copy" : "not in this version (phone-only build)")
    }
    static var overrideForTesting: Verdict?
}
