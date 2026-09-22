import Foundation

/// Plan FS §3 — where a received vault came from, recorded beside its baseline.
///
/// PR1 wrote down where this would go: the same shape as the pack sidecar, read back by the same
/// pattern, so a badge and a job record can say where a vault came from without another registry.
/// This is that sidecar. It holds the publisher (only when a signature actually verified), whether
/// the archive was verified, and the **host** the archive came from — never the link, which may be
/// a purchase capability.
struct VaultReceipt: Codable, Equatable {

    enum Verification: String, Codable, Equatable {
        case signed
        case unverified
    }

    /// Only set when the signature verified against a listed publisher's key.
    let publisherId: String?
    let publisherName: String?
    let verification: Verification
    /// Host only. The path and query of a vault link are never written anywhere.
    let sourceHost: String
    let receivedAt: Date
    /// The archive's SHA-256, so "this is the thing that was reviewed" is checkable after the fact.
    let archiveSHA256: String

    static let filename = "vault-received.json"

    init(publisherId: String?, publisherName: String?, verification: Verification,
         sourceHost: String, receivedAt: Date, archiveSHA256: String) {
        self.publisherId = publisherId
        self.publisherName = publisherName
        self.verification = verification
        self.sourceHost = sourceHost
        self.receivedAt = receivedAt
        self.archiveSHA256 = archiveSHA256
    }

    enum CodingKeys: String, CodingKey {
        case publisherId = "publisher_id"
        case publisherName = "publisher_name"
        case verification
        case sourceHost = "source_host"
        case receivedAt = "received_at"
        case archiveSHA256 = "archive_sha256"
    }

    /// The receipt an outcome produces. Refusals never reach here — nothing is installed from one.
    static func make(verification: VaultArchiveVerification, host: String, now: Date,
                     archiveSHA256: String) -> VaultReceipt {
        let publisher = verification.verifiedPublisher
        return VaultReceipt(publisherId: publisher?.id, publisherName: publisher?.name,
                            verification: publisher == nil ? .unverified : .signed,
                            sourceHost: host, receivedAt: now, archiveSHA256: archiveSHA256)
    }
}

/// What a vault's row, the vault picker, the job line and the work record say about where a vault
/// came from. Nil for every vault that is not a received one — a hand-imported folder, a bundled
/// vault and a signed pack each have their own story and none of them is this.
enum VaultSourceBadge: Equatable {

    /// Installed from a link, unsigned or from a publisher nobody has listed.
    case unverifiedSource
    /// Signed at the time, by a publisher the catalog has since revoked. The vault stays — a
    /// technician may be working from it — and says so everywhere it is named.
    case revokedPublisher(String)

    /// The short label a row shows.
    var label: String {
        switch self {
        case .unverifiedSource: return "Unverified source"
        case .revokedPublisher: return "Publisher revoked"
        }
    }

    /// The line a work record, a PDF and the audit JSON carry.
    func recordLine(vaultName: String) -> String {
        switch self {
        case .unverifiedSource:
            return "Reference vault: \(vaultName) — unverified source."
        case .revokedPublisher(let publisher):
            return "Reference vault: \(vaultName) — publisher \(publisher) is no longer listed."
        }
    }

    /// The sentence under a badged row.
    var explanation: String {
        switch self {
        case .unverifiedSource:
            return "This vault was installed from a link that wasn't signed by a listed publisher. Its reference files guide the assistant's answers."
        case .revokedPublisher(let publisher):
            return "\(publisher) is no longer a listed publisher. This vault is left installed and still works; treat its content as unverified."
        }
    }

    /// The badge for an installed vault, from its sidecar and the publisher list this process has
    /// loaded. Nil — no badge, nothing said — for every vault that did not arrive by link.
    @MainActor
    static func forInstalledVault(id: String) -> VaultSourceBadge? {
        resolve(receipt: VaultImporter.receipt(for: id),
                publishers: VaultPublisherDirectory.shared.loaded)
    }

    /// Pure: what a receipt and the current publisher list amount to.
    static func resolve(receipt: VaultReceipt?, publishers: [VaultPublisher]) -> VaultSourceBadge? {
        guard let receipt else { return nil }
        if let id = receipt.publisherId,
           let publisher = publishers.first(where: { $0.id == id }),
           publisher.status == .revoked {
            return .revokedPublisher(publisher.name)
        }
        return receipt.verification == .unverified ? .unverifiedSource : nil
    }
}
