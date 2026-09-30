import Foundation

/// The first-run flow's page order and the "Add a device" step's answers (Plan FY P2), kept out of
/// the view so the order and the phone path can be walked in a test.
///
/// The flow leads with the assistant — the AI it runs on, its access key, its voice, the
/// permissions it needs and its name — and asks about devices last. This phone is a complete answer
/// to that question: it ends the step with nothing left to finish. Glasses stay one tap away on the
/// same page, because Field Assist technicians do use glasses, though not all the time.
enum OnboardingFlow {

    /// Every page, in the order a first run meets them. The raw value is the page index the view
    /// and `OrgFirstRun` count in.
    enum Page: Int, CaseIterable {
        case welcome
        case provider
        case accessKey
        case services
        case permissions
        case assistantName
        case addDevice
        case ready
    }

    /// The answers the "Add a device" step accepts.
    enum DeviceAnswer: Equatable {
        /// Use this phone. A whole answer on its own: nothing is pending afterwards.
        case thisPhone
        /// Add smart glasses — the camera permission and the Meta AI registration. Registration may
        /// still be waiting for approval when the user carries on; the glasses finish connecting
        /// from Settings, and the phone works in the meantime.
        case glasses
    }

    static var pageCount: Int { Page.allCases.count }

    /// The page after `page` on the forward path; `nil` after Ready, where the flow completes.
    static func page(after page: Page) -> Page? {
        Page(rawValue: page.rawValue + 1)
    }

    /// Where the device step leads. Both answers finish the step, so both lead to Ready.
    static func page(after answer: DeviceAnswer) -> Page { .ready }

    /// Whether the answer means the person uses glasses, which is what `Config.glassesAdded`
    /// records. Choosing this phone records nothing, so choosing it can never leave a
    /// half-finished glasses setup behind.
    static func addsGlasses(_ answer: DeviceAnswer) -> Bool { answer == .glasses }

    /// Whether the glasses rows start open on the device step. Open for someone set up for Field
    /// Assist (a licence, or an organisation's profile), who is the likeliest to be holding a pair;
    /// one tap away for everyone else.
    static func glassesStartOpen(fieldAssistSetUp: Bool) -> Bool { fieldAssistSetUp }

    /// The session card's headline when no glasses are connected. With glasses added, their state
    /// is the news ("Glasses Not Connected", or the registration's own status); without them this
    /// phone is the device, and the card reports the session like any other — so a phone-only user
    /// is never shown a missing device as though setup were unfinished.
    static func phoneIsTheDevice(glassesConnected: Bool, glassesAdded: Bool) -> Bool {
        !glassesConnected && !glassesAdded
    }
}
