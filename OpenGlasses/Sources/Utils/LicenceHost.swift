import Foundation

/// The vendor's licence host (Plan LS): the one place its address is written in the app.
///
/// Every signed licence code already names its profile address on this host
/// (`https://licence.avenkin.com/p/<profileId>`), and the seat service is that address's origin
/// (`DeviceSeatLease.seatOrigin`). Activation is the one lookup that must know the host *before*
/// it has a code: the code is inside the sealed file being looked up. So the host is written here,
/// and `PublicSiteGuardTests` pins it to the origin the codes name and checks no other source file
/// writes it.
///
/// It is not under `PublicSite.baseURL`: the public site is static hosting, this host is the
/// licence service. **Paths here are permanent** once a build reads them, the same rule as the
/// profile addresses inside every code.
enum LicenceHost {

    /// The licence service's public host.
    static let baseURL = URL(string: "https://licence.avenkin.com")!

    /// Where the service serves sealed activation files, one per issued key, named exactly as on
    /// the public site (`ActivationKey.fileName`). Answers are `no-store`; 404 means no key has the
    /// name, 410 that the key was withdrawn, a 5xx that the host could not look
    /// (Contracts/activation-lookup.md). A directory: file names are appended to it.
    static var activationDirectory: URL {
        baseURL.appendingPathComponent("a", isDirectory: true)
    }
}
