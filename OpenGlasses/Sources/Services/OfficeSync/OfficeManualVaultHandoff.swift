import Foundation

extension OfficeManualImport.Prepared {
    /// Handoff to the existing installer, retaining its validation/operation lock and receipt.
    /// The commissioning, entitlement, durable high-water commit and indexing coordinator must
    /// be in place before a production caller invokes installation. Preparation is not Ready.
    @MainActor
    var vaultImportRequest: VaultLinkInstaller.Request {
        let receipt = VaultReceipt.make(verification: verification, host: "Avenkin Office",
                                       now: receivedAt, archiveSHA256: archiveSHA256)
        return .init(files: files, receipt: receipt)
    }
}
