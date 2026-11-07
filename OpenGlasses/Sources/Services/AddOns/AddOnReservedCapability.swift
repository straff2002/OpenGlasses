import Foundation

/// A capability only a **signed** add-on may hold, written `"<name>": true` under `permissions`.
///
/// Reserved capabilities are not permissions the wearer can grant on a sheet: the signature is the
/// grant. `RecipeAddOnValidator` refuses a `community` file that names one, so a premium or
/// organisation file that is copied and edited (and no longer verifies) cannot keep them. What is
/// gated is the capability, not the text: the source of every add-on stays readable.
///
/// In this phase they grant nothing at run time — no step type uses them yet, and `RecipeRunner`
/// ignores them. The steps (a parts lookup, work-record writes), the Keychain store for
/// `credentials` and the office channel are specified with the install phase.
enum AddOnReservedCapability: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Per-add-on secrets held in the Keychain and substituted into header values only — never
    /// into a URL, never available to `say`, `remember` or `display`, never exported or shown.
    case credentials
    /// Read access to the vault parts index (number, description, fits, supersedes). Read-only;
    /// the manuals themselves are not reachable.
    case parts
    /// Write access to the job's work record: a part noted against the active task, a parts
    /// request raised. Every write is attributed to the add-on in the session log.
    case workRecord
    /// The office channel. Reserved so no unsigned file can claim it; what rides it is the office
    /// contracts, not free-form add-on traffic.
    case office

    /// The plain-words line an install sheet shows when the add-on holds this capability. No
    /// internal names: this is what the wearer reads.
    var summaryText: String {
        switch self {
        case .credentials: return "Use a key stored for it on this phone. The key is never shown or spoken."
        case .parts: return "Look up part numbers in your manuals' parts list"
        case .workRecord: return "Note parts against the job you're on"
        case .office: return "Send to your office"
        }
    }
}
