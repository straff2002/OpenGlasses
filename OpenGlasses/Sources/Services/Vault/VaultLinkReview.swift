import Foundation

/// Plan FS §3 — what the review sheet says, decided without a screen.
///
/// Nothing installs from a scan or a paste alone (owner decision 2026-09-21): whatever the link
/// was, what the reader sees is this — the vault, the publisher or the unverified-source warning,
/// the site's **host**, the size, the manuals by title, and the one sentence that says what a
/// vault actually does. The install button's enablement is a function of this value and the
/// acknowledgement, so the gate is provable rather than a view's local state.
struct VaultLinkReview: Equatable {

    let vaultName: String
    let vaultVersion: String
    let vaultId: String
    /// Host only. See `VaultLinkPolicy.displayHost` for why the rest of the link is never shown.
    let host: String
    let totalBytes: Int
    /// Manual titles, in the order the archive lists them.
    let manuals: [String]
    let includesOriginalPDFs: Bool
    let verification: VaultArchiveVerification
    let policy: VaultLinkInstallPolicy
    /// Whether this phone is on cellular data right now.
    let isOnCellular: Bool
    /// The byte size above which a cellular download is worth warning about.
    let cellularWarningBytes: Int
    /// Whether a vault with this id is already installed, and at what version.
    let installedVersion: String?

    init(vaultName: String, vaultVersion: String, vaultId: String, host: String, totalBytes: Int,
         manuals: [String], includesOriginalPDFs: Bool,
         verification: VaultArchiveVerification, policy: VaultLinkInstallPolicy,
         isOnCellular: Bool, cellularWarningBytes: Int, installedVersion: String? = nil) {
        self.vaultName = vaultName
        self.vaultVersion = vaultVersion
        self.vaultId = vaultId
        self.host = host
        self.totalBytes = totalBytes
        self.manuals = manuals
        self.includesOriginalPDFs = includesOriginalPDFs
        self.verification = verification
        self.policy = policy
        self.isOnCellular = isOnCellular
        self.cellularWarningBytes = cellularWarningBytes
        self.installedVersion = installedVersion
    }

    /// The sentence every review carries, signed or not: a vault is not a document the reader
    /// reads, it is content that steers what the assistant says.
    static let groundingSentence =
        "This vault's reference files will guide the assistant's answers while it is selected."

    /// The highlighted block an unverified archive shows. Four short sentences, in the order they
    /// have to be read: what is missing, what that means, what the consequence is, and what to do.
    static let unverifiedWarning = [
        "This vault isn't signed by a listed publisher.",
        "The app can't tell who built it, or whether it was altered on the way here.",
        "Its reference files will steer the assistant's answers.",
        "Only continue if you know and trust the source.",
    ]

    /// The second, explicit acknowledgement an unverified install needs before the button enables.
    static let acknowledgementPrompt = "I know where this vault came from and I accept the risk."

    /// "Signed by Acme Manuals" — only ever from a verified signature.
    var signedLine: String? {
        guard case .signed(_, let name) = verification else { return nil }
        return "Signed by \(name)"
    }

    /// The warning block, or nil when the archive is signed.
    var warningBlock: [String]? {
        guard case .unverified = verification else { return nil }
        return Self.unverifiedWarning
    }

    /// The reason there is no install button at all. Refusals first: a tampered or revoked archive
    /// stops here whatever the policy says, and a policy that forbids unsigned stops the rest.
    var refusal: String? {
        switch verification {
        case .refused(let reason):
            return VaultArchiveVerifier.describe(reason)
        case .unverified:
            return policy.refusalMessage
        case .signed:
            return nil
        }
    }

    /// Whether the reader must tick the acknowledgement before the install button enables.
    var requiresAcknowledgement: Bool {
        guard refusal == nil else { return false }
        if case .unverified = verification { return true }
        return false
    }

    /// The whole enablement rule, in one place.
    func allowsInstall(acknowledged: Bool) -> Bool {
        guard refusal == nil else { return false }
        return requiresAcknowledgement ? acknowledged : true
    }

    /// What the button says: an update names the version it replaces, so "install" never quietly
    /// means "overwrite".
    var installButtonTitle: String {
        guard let installedVersion else { return "Install vault" }
        return "Update from v\(installedVersion)"
    }

    /// The line that explains an update, when this vault id is already here.
    var updateNote: String? {
        guard installedVersion != nil else { return nil }
        return "A vault with this id is already installed. Installing replaces its files; your own edits to the core files are kept."
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
    }

    /// The cellular warning, when it applies. A vault with manuals in it is tens of megabytes and
    /// a technician on a job is very often on a phone plan.
    var cellularWarning: String? {
        guard isOnCellular, totalBytes >= cellularWarningBytes else { return nil }
        return "You're on cellular data and this vault is \(sizeText). It will download over your mobile connection."
    }

    /// What the manuals line says. A vault received by link exists so that nobody has to run text
    /// extraction on a phone, so what it carries is worth stating plainly.
    var manualsSummary: String {
        guard !manuals.isEmpty else { return "No manuals — core files and procedures only." }
        let count = "\(manuals.count) manual\(manuals.count == 1 ? "" : "s"), already read for search"
        return includesOriginalPDFs ? count + ", with the manufacturers' PDFs" : count
    }

    /// The line the audit log records for the review itself, in the terms a reviewer reads. The
    /// host, never the link.
    var auditNote: String {
        let state: String
        switch verification {
        case .signed(let id, _): state = "signed by \(id)"
        case .unverified(.notSigned): state = "unsigned"
        case .unverified(.unknownPublisher(let claimed)):
            state = "unknown publisher \(claimed.isEmpty ? "-" : claimed)"
        case .refused(let reason): state = "refused: \(reason)"
        }
        return "vault=\(vaultId)@\(vaultVersion), host=\(host), bytes=\(totalBytes), \(state)"
    }
}
