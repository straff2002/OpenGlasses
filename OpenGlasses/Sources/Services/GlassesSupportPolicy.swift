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
        #if AVENKIN_PHONE_ONLY
        return "That isn't available in this version of \(appName)."
        #else
        return "Smart glasses aren't supported in this version of \(appName)."
        #endif
    }

    static var current: Verdict {
        // Even a test/developer override cannot add hardware support to the phone product.
        guard AppBuildVariant.current != .phoneOnly else { return .notInThisVersion }
        return overrideForTesting ?? .supported
    }
    static var isSupported: Bool { current == .supported }
    static var reportLine: String {
        #if AVENKIN_PHONE_ONLY
        return "Build variant: " + AppBuildVariant.current.rawValue
        #else
        return "Build variant: " + AppBuildVariant.current.rawValue + " · Glasses: "
            + (isSupported ? "offered by this copy" : "not in this version (phone-only build)")
        #endif
    }
    static var overrideForTesting: Verdict?

    // The fragments tool descriptions and model prompts share. Spelled here so a description stays
    // one literal, and so the beta's wording is the same text it always was.
    #if AVENKIN_PHONE_ONLY
    /// Where a camera tool's picture comes from.
    static let toolCameraSource = "on this phone"
    /// Whose microphone a recording tool uses.
    static let toolMicrophoneSource = "phone"
    /// Whose camera took a picture, before the word "camera".
    static let cameraOwner = "phone"
    /// Where the assistant is, after "You are a …".
    static let assistantPlace = "on the user's phone"
    /// What kind of assistant this is, before the word "assistant".
    static let assistantKind = "voice"
    /// After a role, naming what it is for. Nothing on a phone.
    static let forSmartGlasses = ""
    /// The same, shorter.
    static let forGlasses = ""
    /// Who a support report describes.
    static let reportDevices = "this phone"
    /// Whose view a description is of.
    static let lookingSubject = "the user"
    #else
    static let toolCameraSource = "the glasses when connected, otherwise the phone"
    static let toolMicrophoneSource = "glasses/phone"
    static let cameraOwner = "glasses"
    static let assistantPlace = "on smart glasses"
    static let assistantKind = "smart glasses"
    static let forSmartGlasses = " for smart glasses"
    static let forGlasses = " for glasses"
    static let reportDevices = "this phone and the glasses"
    static let lookingSubject = "a wearer of smart glasses"
    #endif
}
