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

    /// The company's choices this phone can offer, in the profile's order: the on-device model only
    /// where it can be downloaded, Apple Intelligence only where it runs. Nil when the profile names
    /// no choices, or none this phone can offer, so the full provider list is shown rather than a
    /// page with nothing to pick.
    static func offered(choices: [String]?, appleIntelligence: Bool, localModel: Bool) -> [LLMProvider]? {
        let offered = (choices ?? []).compactMap(LLMProvider.init(rawValue:)).filter { provider in
            switch provider {
            case .local: return localModel
            case .appleOnDevice: return appleIntelligence
            default: return true
            }
        }
        return offered.isEmpty ? nil : offered
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

/// Plan ND decision 10: the company sets no language. The app speaks the language iOS gives it, and
/// the managed first run says which, in one line, with a way to change it in iOS Settings.
enum OnboardingLanguage {

    struct Line: Equatable, Sendable {
        /// The language's own name, in the language the app speaks (`English`, `Deutsch`).
        let languageName: String
        /// The app speaks the phone's first language, so the line can say "like your phone".
        let matchesPhone: Bool
    }

    /// - Parameters:
    ///   - appLanguage: the localization the app is running in (`Bundle.main.preferredLocalizations`).
    ///   - phoneLanguages: the phone's languages, first preferred (`Locale.preferredLanguages`).
    static func line(appLanguage: String, phoneLanguages: [String]) -> Line {
        let appCode = Locale(identifier: appLanguage).language.languageCode?.identifier ?? appLanguage
        let phoneCode = phoneLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: appCode) ?? appLanguage
        return Line(languageName: name, matchesPhone: appCode == phoneCode)
    }

    static var current: Line {
        line(appLanguage: Bundle.main.preferredLocalizations.first ?? "en", phoneLanguages: Locale.preferredLanguages)
    }
}
