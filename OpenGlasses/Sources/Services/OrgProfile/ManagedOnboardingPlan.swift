import Foundation

/// Plan ND — the first run on a phone a company manages: only what the person holding it has to do.
///
/// Everything the company decided is already decided, so a managed phone asks only for what nobody
/// else can give: the permissions (iOS lets only the person grant them, and no MDM can grant camera
/// or microphone access to an app), an assistant when the company pinned none, and a look at the
/// language the app speaks. Glasses get one page, only when the edition uses them, because Meta AI's
/// approval cannot be given from a portal. Pure; `OnboardingView` wires it (Plan ND P2).
enum ManagedOnboardingPlan {

    enum Page: Equatable, Sendable {
        /// Set up with the company's key or code, then the enrolment review.
        case welcome
        /// The assistant, from the company's `aiChoices`. Never shown when the company pinned a model.
        case assistant(choices: [String])
        /// The provider list and key pages, as on an unmanaged phone: the profile pins no model and
        /// names no choices (a profile from before ND).
        case providerList
        case permissions
        /// One line naming the language the app speaks, with a way to change it in iOS Settings.
        case language
        case glasses
        case ready
    }

    struct Inputs: Equatable, Sendable {
        /// The profile in force names a model the phone can use (`OrgProfileManager.organizationModel`).
        var organisationChoseModel: Bool
        /// The profile's `aiChoices`, already narrowed to providers this build knows.
        var aiChoices: [String]?
        /// The edition expects glasses on this phone.
        var editionUsesGlasses: Bool
    }

    /// The pages a managed phone shows after Welcome, in order.
    static func pages(_ inputs: Inputs) -> [Page] {
        var pages: [Page] = [.welcome]
        if !inputs.organisationChoseModel {
            if let choices = inputs.aiChoices, !choices.isEmpty {
                pages.append(.assistant(choices: choices))
            } else {
                pages.append(.providerList)
            }
        }
        pages.append(.permissions)
        pages.append(.language)
        if inputs.editionUsesGlasses { pages.append(.glasses) }
        pages.append(.ready)
        return pages
    }

    /// The providers a person may pick from the profile's `aiChoices`: those this build offers, in the
    /// profile's order, each once. Empty means none this build knows — the full list is shown instead.
    static func knownChoices(_ raw: [String]?) -> [String]? {
        guard let raw else { return nil }
        let offered: Set<String> = [LLMProvider.chatgpt.rawValue, LLMProvider.local.rawValue,
                                    LLMProvider.appleOnDevice.rawValue]
        var seen: Set<String> = []
        return raw.filter { offered.contains($0) && seen.insert($0).inserted }
    }
}
