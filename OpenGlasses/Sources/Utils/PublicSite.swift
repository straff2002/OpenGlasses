import Foundation

/// Every public address the app reads, derived from one base (Plan FY P0 item 7).
///
/// The site this repository publishes — the privacy, support and about pages, the signed pack
/// catalogs and the sealed activation files — is served at avenkin.com. Builds before this one read
/// the project's old Pages addresses; those answer with a redirect to the same path here, so the
/// paths below must stay the paths the site already serves. `PublicSiteGuardTests` pins them, and
/// fails on any old Pages or repository address written anywhere else in the sources.
///
/// Per-URL override hooks that already exist (the pack catalogs' `UserDefaults` keys in `Config`)
/// keep working; only their defaults come from here.
enum PublicSite {

    /// The one base every address below is derived from.
    static let baseURL = URL(string: "https://avenkin.com")!

    /// The public privacy policy.
    static var privacy: URL { baseURL.appendingPathComponent("privacy.html") }

    /// Support: how to reach us and how to report a problem, with no account needed.
    static var support: URL { baseURL.appendingPathComponent("support.html") }

    /// The marketing page.
    static var about: URL { baseURL.appendingPathComponent("about.html") }

    /// The signed skill-pack catalog (Plan BX).
    static var skillPackCatalog: URL {
        baseURL.appendingPathComponent("skillpacks").appendingPathComponent("catalog.json")
    }

    /// The signed vault-pack catalog (Plan EG).
    static var vaultPackCatalog: URL {
        baseURL.appendingPathComponent("vaultpacks").appendingPathComponent("catalog.json")
    }

    /// Where sealed activation files are published, one per issued activation key (Plan CT 3a;
    /// `activation/` in `Scripts/stage-pages-site.sh`). A directory: files are appended to it.
    static var activationDirectory: URL {
        baseURL.appendingPathComponent("activation", isDirectory: true)
    }
}
