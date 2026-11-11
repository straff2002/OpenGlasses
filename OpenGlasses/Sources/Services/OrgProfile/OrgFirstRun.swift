import Foundation

/// Plan CT 3a — the decisions behind the first-run "Set up with my company" branch, kept out of
/// the view so they can be tested.
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

    /// Whether the welcome page moves on by itself: the person took "Set up with my company" from
    /// it (a scanned code — an office's or an organisation's — or a key), and the organisation's
    /// profile has just come into force. They go on to `pageAfterWelcome` and the permissions
    /// that follow, rather than back to a welcome page waiting for "Get Started". A declined
    /// review or a refused enrolment leaves the phone unmanaged, so nothing moves; a phone already
    /// managed before the route started does not count as having just been set up.
    static func continuesFromWelcome(tookCompanyRoute: Bool, onWelcomePage: Bool,
                                     wasManaged: Bool, isManaged: Bool) -> Bool {
        tookCompanyRoute && onWelcomePage && !wasManaged && isManaged
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
}
