import XCTest
@testable import OpenGlasses

/// Plan FN PR2 — what the Custom Vaults screen offers for one manual, and what it says afterwards.
///
/// The screen itself is layout; every decision it draws is made here, so the cases that matter are
/// provable without a vault on disk or a view around them: which row offers a destructive action,
/// which one is mid-removal, what stands down while an operation owns the vault, and — the one a
/// reader notices most — which failures are worth alarming them about.
@MainActor
final class VaultManualRowStateTests: XCTestCase {

    private let install = VaultDocument(file: "install.txt", title: "SLP99 Installation Manual",
                                        kind: "install_guide")
    private let service = VaultDocument(file: "service.txt", title: "SLP99 Service Manual",
                                        kind: "service_manual")

    private func entry(for document: VaultDocument, chunks: Int = 412) -> VaultDocumentLedger.Entry {
        VaultDocumentLedger.Entry(file: document.file, title: document.title,
                                  documentId: "doc-\(document.file)", contentHash: "hash",
                                  chunkCount: chunks)
    }

    private func row(_ document: VaultDocument,
                     ledgerEntry: VaultDocumentLedger.Entry? = nil,
                     summary: String? = "412 sections",
                     pending: Set<String> = [],
                     inFlight: String? = nil,
                     eligibility: VaultManualRemoval.Eligibility = .allowed,
                     busy: Bool = false) -> VaultManualRowState {
        VaultManualRowState.make(document: document, ledgerEntry: ledgerEntry, summary: summary,
                                 pendingFiles: pending, inFlightFile: inFlight,
                                 eligibility: eligibility, isVaultBusy: busy)
    }

    // MARK: - What a row offers

    func testAnIndexedManualOfAnImportedVaultOffersRemoval() {
        let state = row(install, ledgerEntry: entry(for: install))
        XCTAssertEqual(state.status, .indexed("412 sections"))
        XCTAssertEqual(state.action, .remove)
        XCTAssertTrue(state.isActionEnabled)
        XCTAssertNil(state.unavailableReason)
        XCTAssertFalse(state.isPendingRemoval)
        XCTAssertEqual(state.action?.title, "Remove manual…", "the ellipsis promises a confirmation")
    }

    func testAnUnindexedManualIsStillRemovable() {
        // A manual that never finished indexing is exactly the one a reader wants out, so the row
        // offers the action rather than treating "no ledger entry" as "nothing to remove".
        let state = row(install, ledgerEntry: nil, summary: nil)
        XCTAssertEqual(state.status, .notIndexed)
        XCTAssertTrue(state.isStatusAdverse)
        XCTAssertEqual(state.action, .remove)
        XCTAssertTrue(state.isActionEnabled)
    }

    func testASignedPacksManualsOfferNothingAndSayWhy() throws {
        let state = row(install, ledgerEntry: entry(for: install),
                        eligibility: .protectedPack(name: "Refrigeration Codes"))
        XCTAssertNil(state.action)
        XCTAssertFalse(state.isActionEnabled)
        let reason = try XCTUnwrap(state.unavailableReason)
        XCTAssertTrue(reason.contains("Refrigeration Codes"), reason)
        XCTAssertTrue(reason.contains("signed pack"), reason)
        XCTAssertNil(state.accessibilityActionHint, "no action, nothing to announce for one")
    }

    func testABundledVaultsManualsOfferNothing() {
        let state = row(install, ledgerEntry: entry(for: install), eligibility: .notInstalled)
        XCTAssertNil(state.action)
        XCTAssertEqual(state.unavailableReason?.contains("ships with the app"), true)
    }

    // MARK: - Pending and in-flight

    func testAManualBeingRemovedSaysSoAndCannotBeStartedAgain() {
        let state = row(install, ledgerEntry: entry(for: install),
                        pending: ["install.txt"], inFlight: "install.txt")
        XCTAssertEqual(state.status, .removing)
        XCTAssertEqual(state.statusText, "Removing…")
        XCTAssertTrue(state.isPendingRemoval)
        XCTAssertFalse(state.isActionEnabled)
        XCTAssertEqual(state.accessibilityLabel, "SLP99 Installation Manual, removing")
    }

    func testAnUnfinishedRemovalIsNeverShownAsAvailable() {
        // The journal still holds it and nothing is running: the manual is already unreachable to
        // retrieval, so a section count would be a lie and Retry is the only honest action.
        let state = row(install, ledgerEntry: entry(for: install), pending: ["install.txt"])
        XCTAssertEqual(state.status, .removalIncomplete)
        XCTAssertEqual(state.statusText, "Removal incomplete")
        XCTAssertTrue(state.isStatusAdverse)
        XCTAssertTrue(state.isPendingRemoval)
        XCTAssertEqual(state.action, .retryRemoval)
        XCTAssertEqual(state.action?.title, "Retry removal")
        XCTAssertTrue(state.isActionEnabled)
    }

    func testPendingIsPerManualAndNotPerVault() {
        let other = row(service, ledgerEntry: entry(for: service, chunks: 88),
                        summary: "88 sections", pending: ["install.txt"])
        XCTAssertEqual(other.status, .indexed("88 sections"))
        XCTAssertFalse(other.isPendingRemoval)
    }

    // MARK: - Standing down while the vault is busy

    func testABusyVaultDisablesEveryRemovalWithoutHidingIt() {
        let state = row(install, ledgerEntry: entry(for: install), busy: true)
        XCTAssertEqual(state.action, .remove, "the action stays on screen")
        XCTAssertFalse(state.isActionEnabled, "…and refuses while an operation owns the vault")
    }

    func testARemovalOfAnotherManualDisablesThisOne() {
        let state = row(service, ledgerEntry: entry(for: service), inFlight: "install.txt", busy: true)
        XCTAssertFalse(state.isActionEnabled)
    }

    // MARK: - VoiceOver

    func testTheSpokenRowCarriesBothFactsTheSightedRowCarries() {
        XCTAssertEqual(row(install, ledgerEntry: entry(for: install)).accessibilityLabel,
                       "SLP99 Installation Manual, 412 sections")
        XCTAssertEqual(row(install, ledgerEntry: nil, summary: nil).accessibilityLabel,
                       "SLP99 Installation Manual, not indexed")
        XCTAssertEqual(row(install, ledgerEntry: entry(for: install), pending: ["install.txt"])
            .accessibilityLabel, "SLP99 Installation Manual, removal incomplete")
    }

    func testTheActionHintSaysWhatHappensAndThatConfirmationComesFirst() throws {
        let hint = try XCTUnwrap(row(install, ledgerEntry: entry(for: install)).accessibilityActionHint)
        XCTAssertTrue(hint.contains("confirm"), hint)
        let retryHint = try XCTUnwrap(row(install, ledgerEntry: entry(for: install),
                                          pending: ["install.txt"]).accessibilityActionHint)
        XCTAssertTrue(retryHint.contains("already unavailable"), retryHint)
    }

    func testNoRenderedStringNamesAPlanLetter() {
        // Internal plan letters belong in comments, never in something a reader can read.
        let strings = [VaultManualRemovalPresentation.confirmationBody,
                       VaultManualRemovalPresentation.confirmationTitle(manual: "M"),
                       VaultManualRemovalPresentation.confirmationMessage(manual: "M", vault: "V"),
                       VaultManualRemovalPresentation.removedCitationNotice(manual: "M"),
                       VaultManualRemovalPresentation.unknownCitationNotice(manual: "M"),
                       VaultManualRowState.Action.remove.title,
                       VaultManualRowState.Action.retryRemoval.title,
                       row(install, ledgerEntry: entry(for: install)).accessibilityActionHint ?? ""]
        for text in strings {
            XCTAssertFalse(text.contains("Plan "), text)
            XCTAssertFalse(text.range(of: #"\bFN\b"#, options: .regularExpression) != nil, text)
        }
    }

    // MARK: - The confirmation

    func testTheConfirmationNamesTheManualTheVaultAndWhatSurvives() {
        let title = VaultManualRemovalPresentation.confirmationTitle(manual: "SLP99 Installation Manual")
        XCTAssertEqual(title, "Remove “SLP99 Installation Manual”?")

        let message = VaultManualRemovalPresentation.confirmationMessage(
            manual: "SLP99 Installation Manual", vault: "Lennox SLP99")
        XCTAssertTrue(message.contains("SLP99 Installation Manual"))
        XCTAssertTrue(message.contains("Lennox SLP99"))
        XCTAssertTrue(message.hasSuffix(VaultManualRemovalPresentation.confirmationBody))
        // The three promises the plan settled, verbatim.
        XCTAssertTrue(message.contains("this device's vault and search index"))
        XCTAssertTrue(message.contains("Existing conversations and core reference files are unchanged."))
        XCTAssertTrue(message.contains("Importing a vault containing this manual again can restore it."))
    }

    // MARK: - What an attempt comes to

    private func result(remaining: Int) -> VaultManualRemoval.RemovalResult {
        VaultManualRemoval.RemovalResult(vaultId: "v", file: "install.txt",
                                         title: "SLP99 Installation Manual", documentId: "doc-1",
                                         chunksRemoved: 412, remainingDocuments: remaining,
                                         removedFiles: ["documents/install.txt"], keptSharedFiles: [])
    }

    func testSuccessReportsTheCountAndDoesNotClaimAModelHasForgotten() {
        let outcome = VaultManualRemovalPresentation.success(result(remaining: 1), vaultName: "Lennox SLP99")
        XCTAssertFalse(outcome.isFailure)
        XCTAssertFalse(outcome.isRetryable)
        XCTAssertTrue(outcome.message.contains("Removed “SLP99 Installation Manual”"))
        XCTAssertTrue(outcome.message.contains("Lennox SLP99 now has 1 manual."))
        XCTAssertTrue(outcome.message.contains("Earlier conversations may still quote it"))
        XCTAssertTrue(outcome.message.contains("start a new conversation"))
        // The one claim that would be false: nothing deleted here reaches what a model was sent.
        XCTAssertFalse(outcome.message.lowercased().contains("forgot"))
        XCTAssertFalse(outcome.message.lowercased().contains("erased"))
    }

    func testRemovingTheLastManualLeavesAValidVaultAndSaysSo() {
        let outcome = VaultManualRemovalPresentation.success(result(remaining: 0), vaultName: "Lennox SLP99")
        XCTAssertTrue(outcome.message.contains("now has no manuals."), outcome.message)
        XCTAssertFalse(outcome.isFailure)
    }

    func testAnUnknownDocumentIsAStaleListAndNotAFailure() {
        // Repeating a removal that finished throws `unknownDocument`, because nothing of the manual
        // is left to address. Reporting that as an error would alarm a reader about the one case
        // where everything went right.
        let outcome = VaultManualRemovalPresentation.outcome(
            for: VaultManualRemoval.RemovalError.unknownDocument(file: "install.txt", vaultId: "v"),
            manual: "SLP99 Installation Manual", vaultName: "Lennox SLP99")
        XCTAssertEqual(outcome, .alreadyGone("“SLP99 Installation Manual” is no longer in Lennox SLP99."))
        XCTAssertFalse(outcome.isFailure)
        XCTAssertFalse(outcome.isRetryable)
    }

    func testCleanupFailureIsRetryableAndSaysTheManualStaysUnavailable() {
        let outcome = VaultManualRemovalPresentation.outcome(
            for: VaultManualRemoval.RemovalError.cleanupFailed("the ledger could not be written"),
            manual: "SLP99 Installation Manual", vaultName: "Lennox SLP99")
        XCTAssertTrue(outcome.isRetryable)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertTrue(outcome.message.contains("the ledger could not be written"))
        XCTAssertTrue(outcome.message.contains("stays unavailable"))
    }

    func testRepairRequiredExplainsThatReImportingFixesIt() {
        let outcome = VaultManualRemovalPresentation.outcome(
            for: VaultManualRemoval.RemovalError.repairRequired("the ledger cannot be read"),
            manual: "SLP99 Installation Manual", vaultName: "Lennox SLP99")
        XCTAssertFalse(outcome.isRetryable, "trying again cannot establish ownership")
        XCTAssertTrue(outcome.isFailure)
        XCTAssertTrue(outcome.message.contains("Importing this vault's folder again repairs"),
                      outcome.message)
    }

    func testAProtectedPackRefusalIsBlockedRatherThanRetryable() {
        let outcome = VaultManualRemovalPresentation.outcome(
            for: VaultManualRemoval.RemovalError.protectedPack("Refrigeration Codes"),
            manual: "A Manual", vaultName: "Refrigeration Codes")
        XCTAssertFalse(outcome.isRetryable)
        XCTAssertTrue(outcome.isFailure)
    }

    func testAnUnexpectedErrorIsOfferedAsRetryableRatherThanSwallowed() {
        struct Odd: LocalizedError { var errorDescription: String? { "disk went away" } }
        let outcome = VaultManualRemovalPresentation.outcome(for: Odd(), manual: "A Manual",
                                                             vaultName: "V")
        XCTAssertTrue(outcome.isRetryable)
        XCTAssertTrue(outcome.message.contains("disk went away"))
    }

    // MARK: - Citations to a manual that has gone

    func testTheRemovedAndUnknownNoticesSayDifferentThings() {
        let removed = VaultManualRemovalPresentation.removedCitationNotice(manual: "SLP99 Service Manual")
        XCTAssertTrue(removed.hasPrefix("Manual removed from this vault."), removed)
        XCTAssertTrue(removed.contains("SLP99 Service Manual"))
        XCTAssertTrue(removed.contains("earlier answers may still quote it"))

        // "Removed" would be a claim about something that may never have been here.
        let unknown = VaultManualRemovalPresentation.unknownCitationNotice(manual: "Someone Else's Manual")
        XCTAssertFalse(unknown.contains("removed"))
        XCTAssertTrue(unknown.contains("No manual in this vault"))
    }

    func testEntitlementDoesNotGateRemovingInstalledContent() {
        // Importing manuals is the paid capability; deleting your own installed content is not, so
        // a lapsed team can still take a superseded manual out of a vault it works from.
        XCTAssertTrue(VaultManualRemoval.isPermittedByEntitlement)
    }
}
