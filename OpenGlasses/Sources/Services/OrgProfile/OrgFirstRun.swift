import Foundation

/// Plan CT 3a — the decisions behind the first-run "My company gave me a key or code" branch, kept
/// out of the view so they can be tested.
enum OrgFirstRun {

    /// The organisation a first-run phone is being set up for: the active licence names its
    /// organisation's profile, and that profile is not in force yet. While this is non-nil,
    /// onboarding holds on "Setting up for …" and does not fall through to the general app — the
    /// organisation's bounds live in the profile, and a phone that opens as the full app while
    /// they are pending is exactly what a partner-configured phone must not do.
    static func holdingLicensee(licence: LicenseService.LicensePayload?, isManaged: Bool) -> String? {
        guard !isManaged, let licence, licence.profile != nil else { return nil }
        return licence.licensee
    }

    /// Where "Get Started" leads: past the provider and key pages when the organisation chose the
    /// model (its key was entered, or waits for the administrator, on the review sheet).
    static func pageAfterWelcome(organisationChoseModel: Bool) -> Int {
        organisationChoseModel ? servicesPage : providerPage
    }

    /// Where Back leads from `page`: straight to the welcome page from the first page after it.
    static func pageBefore(_ page: Int, organisationChoseModel: Bool) -> Int {
        organisationChoseModel && page == servicesPage ? 0 : max(page - 1, 0)
    }

    static let providerPage = 1
    static let servicesPage = 3

    /// What is typed into the key field. An attempt at an activation key is upper-cased and grouped
    /// in fours as it is typed; anything else — a pasted licence code — is left exactly as it is.
    static func formatKeyEntry(_ text: String) -> String {
        let compact = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard !compact.isEmpty, compact.count <= ActivationKey.length,
              compact.allSatisfy({ ActivationKey.alphabet.contains($0) || "OILU".contains($0) }) else {
            return text
        }
        let characters = Array(compact)
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }
}
