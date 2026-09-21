import Foundation

/// What the Custom Vaults screen shows for one manual of one installed vault.
///
/// Pure over the values that screen already holds — the manifest row, the ledger entry, the
/// journal's pending set, whether an operation owns the vault, and what the entitlement policy
/// says — so the decisions a destructive action turns on are testable without a vault on disk or a
/// view around them. The view keeps layout and the `await`; nothing it draws is decided inline.
struct VaultManualRowState: Equatable, Identifiable {

    /// What the row says about the manual itself.
    enum Status: Equatable {
        /// Indexed, with the ledger's own summary ("412 sections · 11 diagram pages").
        case indexed(String)
        /// The manifest lists it and the index does not hold it.
        case notIndexed
        /// A removal started from this screen is running.
        case removing
        /// A removal was recorded and did not finish. The manual is already unreachable —
        /// everything that reads the vault treats a pending target as gone — so the row says that
        /// rather than a section count which no longer means anything.
        case removalIncomplete
    }

    /// The destructive action a row offers, if any.
    enum Action: Equatable {
        case remove
        case retryRemoval

        /// The button's words. A trailing ellipsis because a confirmation follows.
        var title: String {
            switch self {
            case .remove: return "Remove manual…"
            case .retryRemoval: return "Retry removal"
            }
        }
    }

    let file: String
    let title: String
    let status: Status
    /// Nil for a vault whose manuals are not the reader's to remove.
    let action: Action?
    /// False while another operation owns this vault — an import, a re-index, an uninstall, or
    /// another manual's removal. The action stays on screen and refuses rather than vanishing from
    /// under the finger reaching for it.
    let isActionEnabled: Bool
    /// Why no action is offered, when none is. Nil when one is.
    let unavailableReason: String?

    var id: String { file }

    /// Everything the row's trailing label says, in the words the screen uses.
    var statusText: String {
        switch status {
        case .indexed(let summary): return summary
        case .notIndexed: return "not indexed"
        case .removing: return "Removing…"
        case .removalIncomplete: return "Removal incomplete"
        }
    }

    /// Whether the status reads as something wrong rather than something ordinary.
    var isStatusAdverse: Bool {
        switch status {
        case .notIndexed, .removalIncomplete: return true
        case .indexed, .removing: return false
        }
    }

    /// A manual with a removal in flight — this screen's, or one an earlier run left unfinished.
    /// Never presented as available: its passages and its page have already stopped answering.
    var isPendingRemoval: Bool {
        status == .removing || status == .removalIncomplete
    }

    // MARK: - VoiceOver

    /// What a screen reader says for the row, which has to carry the same two facts the sighted
    /// row carries in two separate labels: which manual, and what state it is in.
    var accessibilityLabel: String {
        switch status {
        case .indexed(let summary): return "\(title), \(summary)"
        case .notIndexed: return "\(title), not indexed"
        case .removing: return "\(title), removing"
        case .removalIncomplete: return "\(title), removal incomplete"
        }
    }

    /// What the row's action does, spoken. Nil when the row offers none — the reason is read as
    /// the row's own text then, so nothing is announced twice.
    var accessibilityActionHint: String? {
        switch action {
        case .remove: return "Removes this manual from the vault on this device. You confirm first."
        case .retryRemoval: return "Finishes removing this manual. It is already unavailable."
        case nil: return nil
        }
    }

    // MARK: - Deciding a row

    /// The row for one manifest document.
    ///
    /// - Parameters:
    ///   - document: the manifest row, which is the manual's identity — the file name, never the
    ///     displayed title.
    ///   - ledgerEntry: what the index recorded for it, when it was indexed.
    ///   - pendingFiles: file names the vault's removal journal has an unfinished removal for.
    ///   - inFlightFile: the file this screen is removing right now, if any.
    ///   - eligibility: whether this vault accepts individual removal at all.
    ///   - isVaultBusy: an import, re-index, uninstall or another removal owns the vault.
    static func make(document: VaultDocument,
                     ledgerEntry: VaultDocumentLedger.Entry?,
                     summary: String?,
                     pendingFiles: Set<String>,
                     inFlightFile: String?,
                     eligibility: VaultManualRemoval.Eligibility,
                     isVaultBusy: Bool) -> VaultManualRowState {
        let isPending = pendingFiles.contains(document.file)
        let isInFlight = inFlightFile == document.file
        let status: Status
        if isInFlight {
            status = .removing
        } else if isPending {
            status = .removalIncomplete
        } else if ledgerEntry != nil, let summary {
            status = .indexed(summary)
        } else {
            status = .notIndexed
        }

        let action: Action?
        let reason: String?
        switch eligibility {
        case .allowed:
            action = (status == .removalIncomplete) ? .retryRemoval : .remove
            reason = nil
        case .protectedPack(let name):
            action = nil
            reason = "“\(name)” is a signed pack, so its manuals are the publisher's to change. "
                + "Remove the whole pack to take them off this device."
        case .notInstalled:
            action = nil
            reason = "This vault ships with the app. Its manuals cannot be removed one at a time."
        }

        // A removal already running for *this* manual is not something to start again; one running
        // for another manual of the same vault is, once the lock lets go.
        let enabled = action != nil && !isVaultBusy && !isInFlight
        return VaultManualRowState(file: document.file, title: document.title, status: status,
                                   action: action, isActionEnabled: enabled, unavailableReason: reason)
    }
}

/// The words the removal flow says: the confirmation, what a success reports, and what each failure
/// means to the reader.
///
/// Separated from the view for the same reason the row state is: the copy is the product decision
/// here. A confirmation that does not say what survives, or a success that lets the reader believe
/// a model has forgotten something, is the defect — not a layout problem.
enum VaultManualRemovalPresentation {

    /// The confirmation's body, exactly as Plan FN settled it. Three sentences, because the reader
    /// is being asked about three different things: the index, what is untouched, and whether this
    /// can be undone.
    static let confirmationBody =
        "Remove this manual from this device's vault and search index? "
        + "Existing conversations and core reference files are unchanged. "
        + "Importing a vault containing this manual again can restore it."

    /// The dialog's title. It names the manual, because a vault row and a manual row are inches
    /// apart and only one of them deletes the whole vault.
    static func confirmationTitle(manual: String) -> String {
        "Remove “\(manual)”?"
    }

    /// The dialog's message: which manual, which vault, then the body.
    static func confirmationMessage(manual: String, vault: String) -> String {
        "“\(manual)” in \(vault).\n\n" + confirmationBody
    }

    /// What the screen does with the result of an attempt.
    enum Outcome: Equatable {
        /// It worked.
        case removed(String)
        /// There was nothing left to remove: this screen's list was stale, which is not a failure
        /// and must not be dressed as one. Refresh and say so plainly.
        case alreadyGone(String)
        /// It failed part-way. The manual stays unavailable and trying again can finish it.
        case retryable(String)
        /// It failed and trying again cannot help until the vault is repaired or re-imported.
        case blocked(String)

        var message: String {
            switch self {
            case .removed(let text), .alreadyGone(let text), .retryable(let text), .blocked(let text):
                return text
            }
        }

        /// Whether the screen offers a Retry alongside the message.
        var isRetryable: Bool {
            if case .retryable = self { return true }
            return false
        }

        /// Whether this reads as a failure. `alreadyGone` deliberately does not.
        var isFailure: Bool {
            switch self {
            case .removed, .alreadyGone: return false
            case .retryable, .blocked: return true
            }
        }
    }

    /// What a completed removal reports.
    ///
    /// The last sentence is the honest limit and is not optional: the passages that already went to
    /// a model are still in that conversation, and no deletion on this phone reaches them. Saying
    /// a new conversation gives a clean result is true; saying the model has forgotten the manual
    /// would not be.
    static func success(_ result: VaultManualRemoval.RemovalResult, vaultName: String) -> Outcome {
        .removed("Removed “\(result.title)”. \(vaultName) now has \(manualCount(result.remainingDocuments)). "
            + "Earlier conversations may still quote it; start a new conversation for a clean result.")
    }

    /// What a thrown removal means to the reader.
    static func outcome(for error: Error, manual: String, vaultName: String) -> Outcome {
        guard let removal = error as? VaultManualRemoval.RemovalError else {
            return .retryable("Removing “\(manual)” did not finish: \(error.localizedDescription)")
        }
        switch removal {
        case .unknownDocument:
            // The manifest no longer lists it and nothing is left pending: it has already gone,
            // and the only thing wrong is this screen's copy of the list.
            return .alreadyGone("“\(manual)” is no longer in \(vaultName).")
        case .cleanupFailed(let detail):
            return .retryable("Removing “\(manual)” did not finish: \(detail). "
                + "It stays unavailable until the removal completes — try again.")
        case .repairRequired(let detail):
            return .blocked("“\(manual)” cannot be removed yet: \(detail). "
                + "Importing this vault's folder again repairs its manual index.")
        case .protectedPack, .notInstalled, .invalidPath:
            return .blocked(removal.errorDescription ?? "“\(manual)” cannot be removed from this vault.")
        }
    }

    /// The notice a citation to a manual this vault no longer holds puts on screen, in place of
    /// opening a page that is not there or doing nothing at all.
    static func removedCitationNotice(manual: String) -> String {
        "Manual removed from this vault. “\(manual)” is no longer on this device; "
            + "earlier answers may still quote it."
    }

    /// The same notice for a citation this vault cannot place at all — a title no manual in it
    /// answers to. Distinct wording, because "removed" would be a claim about something that may
    /// never have been here.
    static func unknownCitationNotice(manual: String) -> String {
        "No manual in this vault answers to “\(manual)”."
    }

    static func manualCount(_ count: Int) -> String {
        switch count {
        case 0: return "no manuals"
        case 1: return "1 manual"
        default: return "\(count) manuals"
        }
    }
}
