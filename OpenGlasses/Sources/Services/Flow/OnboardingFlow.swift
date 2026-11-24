import Foundation

/// The first-run flow's page order and the "Add a device" step's answers (Plan FY P2), kept out of
/// the view so the order and the phone path can be walked in a test.
///
/// The flow leads with the assistant — the AI it runs on, its access key, its voice, the
/// permissions it needs and its name — and asks about devices last. This phone is a complete answer
/// to that question: it ends the step with nothing left to finish. Glasses stay one tap away on the
/// same page, because Field Assist technicians do use glasses, though not all the time.
enum OnboardingFlow {

    /// Every page a first run can meet. Which of them it meets, and in what order, is `route`.
    enum Page: Int, CaseIterable {
        case welcome
        case provider
        case accessKey
        case services
        case permissions
        /// Plan ND: the language the app speaks, in one line. Only on a phone a company manages.
        case language
        case assistantName
        case addDevice
        case ready
    }

    /// The pages of a first run on a phone nobody manages, in order: every page but the language line.
    static let unmanagedRoute: [Page] = [.welcome, .provider, .accessKey, .services, .permissions,
                                         .assistantName, .addDevice, .ready]

    /// The pages this first run walks, in order (Plan ND P2). A phone a company manages walks
    /// `ManagedOnboardingPlan`'s shorter list; any other walks `unmanagedRoute`.
    static func route(managed: ManagedOnboardingPlan.Inputs?) -> [Page] {
        guard let managed else { return unmanagedRoute }
        return ManagedOnboardingPlan.pages(managed).flatMap { page -> [Page] in
            switch page {
            case .welcome: return [.welcome]
            // The company's choices and the full list are both the provider page (narrowed to the
            // choices), then the page that connects what was picked.
            case .assistant, .providerList: return [.provider, .accessKey]
            case .permissions: return [.permissions]
            case .language: return [.language]
            case .glasses: return [.addDevice]
            case .ready: return [.ready]
            }
        }
    }

    /// The page after `page` on `route`; `nil` after its last page, where the flow completes. A page
    /// the route does not hold (the company's profile arrived and changed the route under it) leads
    /// to the first page after Welcome.
    static func page(after page: Page, in route: [Page]) -> Page? {
        guard let index = route.firstIndex(of: page) else { return route.dropFirst().first }
        let next = route.index(after: index)
        return next < route.endIndex ? route[next] : nil
    }

    /// Where Back leads from `page` on `route`: the page before it, or Welcome.
    static func page(before page: Page, in route: [Page]) -> Page {
        guard let index = route.firstIndex(of: page), index > route.startIndex else { return route.first ?? .welcome }
        return route[route.index(before: index)]
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

    /// Where the device step leads. Both answers finish the step, so both lead to Ready.
    static func page(after answer: DeviceAnswer) -> Page { .ready }

    /// Whether the answer means the person uses glasses, which is what `Config.glassesAdded`
    /// records. Choosing this phone records nothing, so choosing it can never leave a
    /// half-finished glasses setup behind.
    static func addsGlasses(_ answer: DeviceAnswer) -> Bool { answer == .glasses }

    /// Whether the glasses rows start open on the device step. Open for someone set up for Field
    /// Assist (a licence, or an organisation's profile), who is the likeliest to be holding a pair;
    /// one tap away for everyone else — and never open on a copy that offers no glasses (Plan JE),
    /// where the view shows no glasses section at all.
    static func glassesStartOpen(fieldAssistSetUp: Bool, glassesSupported: Bool) -> Bool {
        glassesSupported && fieldAssistSetUp
    }

    /// The session card's headline when no glasses are connected. With glasses added, their state
    /// is the news ("Glasses Not Connected", or the registration's own status); without them this
    /// phone is the device, and the card reports the session like any other — so a phone-only user
    /// is never shown a missing device as though setup were unfinished.
    static func phoneIsTheDevice(glassesConnected: Bool, glassesAdded: Bool) -> Bool {
        !glassesConnected && !glassesAdded
    }
}
