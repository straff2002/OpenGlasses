import Foundation

/// Plan NH §2 — who is never counted and never refused. Pure: every signal is passed in, so each
/// exemption is a value test and nothing here reads StoreKit, a licence, the accessibility state or
/// the build.
///
/// An exempt user's time is not recorded at all, and they never see a counter.
enum AllowanceExemption {

    struct Inputs: Equatable {
        // 1. A paid tier or licence (decision 6).
        /// The Standard subscription.
        var standardActive = false
        /// The My Manuals subscription.
        var myManualsActive = false
        /// Field Assist at any tier: a store subscription, the retired unlock, a licence code or an
        /// organisation's licence (`FieldAssistEntitlement`).
        var fieldAssistGranted = false
        /// Medical Compliance (`StoreKitService.isMedicalComplianceActive`).
        var medicalActive = false
        /// An organisation profile is in force (`PolicyEnvelope.isManaged`).
        var organisationProfile = false
        /// StoreKit has not yet read this phone's purchases. Unknown is not "none": a subscriber is
        /// never refused in the second before their receipt is read.
        var purchasesUnread = false

        // 2. Accessibility (decision 4). Never a product, an entitlement or a paywall (Plan A).
        var voiceOverRunning = false
        /// Settings › Accessibility mode.
        var accessibilityModeOn = false
        /// An assistive mode is running, or the Blind Assistant is the chosen live mode.
        var assistiveModeActive = false

        // 3. First aid (decision 5).
        /// This turn asks for first aid (`FirstAidTurnRecognizer`).
        var firstAidTurn = false
        /// A first-aid protocol, CPR or AED guidance, is running.
        var firstAidSessionActive = false

        // 4. The build (decision 9).
        /// Installed from the App Store. TestFlight, Xcode and the simulator are unmetered…
        var isStoreBuild = false
        /// …unless the developer setting "Meter as a store build" is on.
        var meterAsStoreBuild = false
    }

    enum Reason: String, Equatable, CaseIterable {
        case paidTier
        case purchasesUnread
        case accessibility
        case firstAid
        case unmeteredBuild
    }

    /// Every reason that applies, in a fixed order.
    static func reasons(_ inputs: Inputs) -> [Reason] {
        var reasons: [Reason] = []
        if inputs.standardActive || inputs.myManualsActive || inputs.fieldAssistGranted
            || inputs.medicalActive || inputs.organisationProfile {
            reasons.append(.paidTier)
        }
        if inputs.purchasesUnread { reasons.append(.purchasesUnread) }
        if inputs.voiceOverRunning || inputs.accessibilityModeOn || inputs.assistiveModeActive {
            reasons.append(.accessibility)
        }
        if inputs.firstAidTurn || inputs.firstAidSessionActive { reasons.append(.firstAid) }
        if !inputs.isStoreBuild && !inputs.meterAsStoreBuild { reasons.append(.unmeteredBuild) }
        return reasons
    }

    static func isExempt(_ inputs: Inputs) -> Bool { !reasons(inputs).isEmpty }
}
