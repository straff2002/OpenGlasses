import Foundation

/// Where a team-learning bundle that arrives on this phone goes (Plan FP P3) — opened from Mail,
/// Messages, AirDrop or Files, or read out of an imported vault folder.
///
/// **A bundle from another phone is untrusted input** (FP §2). `LearningBundle.decode` checks its
/// structure and nothing else; what happens next depends on its direction, and in neither case is
/// anything approved or applied because it arrived:
///
/// - **`candidates`** (field → reviewer) lands in this device's `LearningCandidateStore` as
///   candidates awaiting review — `received`, origin kept, with an `importedFrom` note — and goes
///   through `LearningReview` exactly like a local one, author-as-approver rule included. Only a
///   reviewer device takes them, because candidates travel to the reviewer and nowhere else.
/// - **`decisions`** (reviewer → field) is **staged**. `pending` shows every entry, status and
///   retraction in it with its full literal text, and nothing reaches the stores or the corpus
///   until someone accepts it: `accept(entryIDs:candidateIDs:)` for the ones chosen, `acceptAll()`,
///   or `discard()`, which leaves no trace. Accepting applies through `LearningBundleMerge`, then
///   `LearningCorpus` — a delta, never a whole-set replace.
///
/// **Gates.** HIPAA mode: no bundle in at all. Importing candidates and accepting entries or
/// statuses ask the `.teamLearnings` capability; a retraction is accepted on any licence, because
/// taking an answer out of service is always allowed (P2) and published learnings stay readable on
/// a lapsed licence. A decisions bundle older than one already applied under the same organisation
/// label is refused (`reordered`); candidates bundles are not ordered this way, because many phones
/// send under one label and each candidate carries its own revision.
///
/// No screen yet: P4 puts the review on this service.
@MainActor
final class LearningBundleIntake: ObservableObject {

    static let shared = LearningBundleIntake()

    let candidates: LearningCandidateStore
    let entries: LearningEntryStore
    /// Where accepted entries are published. Nil without a document index: the entries are kept
    /// and `LearningReviewService.republish()` puts them in place later.
    var documentStore: DocumentStore?

    var capability: () -> FieldAssistCapabilityCheck = { FieldAssistEntitlement.shared.check(.teamLearnings) }
    var hipaaMode: () -> Bool = { Config.hipaaMode }
    var isReviewerDevice: () -> Bool = { Config.teamLearningReviewerDevice }
    var vaults: () -> [LearningCorpus.VaultTarget] = { LearningReviewService.installedVaults() }
    /// Writes a candidate's new status onto the job it was filed on — the author's session and
    /// job record — saying whether an entry made from it now answers here.
    var recordStatus: (LearningCandidate, Bool) -> Void = { candidate, inUse in
        FieldSessionService.shared.recordTeamLearning(.teamLearningStatus, reference: candidate.reference(inUse: inUse),
                                                      sessionId: candidate.sessionId)
    }
    var clock: () -> Date = Date.init

    init(candidates: LearningCandidateStore? = nil, entries: LearningEntryStore? = nil,
         documentStore: DocumentStore? = nil) {
        self.candidates = candidates ?? .shared
        self.entries = entries ?? .shared
        self.documentStore = documentStore
    }

    // MARK: - What is waiting

    /// A decisions bundle waiting for someone to accept what is in it.
    struct Staged: Equatable {
        let bundle: LearningBundle
        let redactionsOnIntake: [String]
        let fileName: String?
        let receivedAt: Date
    }

    @Published private(set) var staged: Staged?
    /// One line about the last file opened, for whoever opened it.
    @Published private(set) var lastMessage: String?

    /// What a staged bundle would do, item by item, with its literal text.
    struct Pending: Equatable {
        enum Change: String, Equatable {
            /// Not on this phone.
            case new
            /// On this phone, and this copy would replace it (a later approval).
            case update
            /// On this phone already; accepting changes nothing.
            case unchanged
            /// On this phone and already retracted here: it stays retracted.
            case retractedHere
        }

        struct Entry: Equatable {
            let entryID: String
            let citationName: String
            /// The text exactly as it would be retrieved and quoted.
            let text: String
            let wire: LearningBundle.Entry
            let change: Change
        }

        struct Status: Equatable {
            let candidateID: String
            let decision: LearningBundle.Decision
            let reason: String?
            /// Whether the candidate it answers was filed on this phone.
            let isOurs: Bool
        }

        struct Retraction: Equatable {
            let entryID: String
            let reason: String
            /// Whether this phone holds the entry it withdraws.
            let isHeld: Bool
        }

        var entries: [Entry] = []
        var statuses: [Status] = []
        var retractions: [Retraction] = []
        var redactionsOnIntake: [String] = []

        var isEmpty: Bool { entries.isEmpty && statuses.isEmpty && retractions.isEmpty }
    }

    var pending: Pending? { staged.map(pending(for:)) }

    // MARK: - Refusals

    enum Refusal: Error, Equatable {
        case hipaa
        case notEntitled(String)
        case notAReviewerDevice
        case bundle(LearningBundle.Refusal)
        case nothingStaged
        case unknownItems([String])
        case unreadable

        var message: String {
            switch self {
            case .hipaa:
                return "Team learnings are unavailable while HIPAA mode is on: the file was not opened."
            case .notEntitled(let reason): return reason
            case .notAReviewerDevice:
                return "These are findings for a reviewer, and this phone isn't a reviewer device. Send the file to "
                    + "whoever reviews your team's learnings."
            case .bundle(let refusal): return refusal.message
            case .nothingStaged: return "There's no team-learning file waiting to be accepted."
            case .unknownItems(let ids):
                return "Nothing was applied: \(ids.map { String($0.prefix(6)) }.joined(separator: ", ")) "
                    + "isn't in the waiting file."
            case .unreadable: return "The team-learning file couldn't be read."
            }
        }
    }

    /// What receiving a bundle did.
    enum Receipt: Equatable {
        /// Candidates added to the review queue on this reviewer device.
        case imported(LearningBundleMerge.Report, redactionsOnIntake: [String])
        /// Decisions staged, waiting to be accepted.
        case staged(Pending)
    }

    // MARK: - Receiving

    /// Whether a file the system handed over is one this route takes: JSON, opened as a copy.
    nonisolated static func isCandidateFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "json"
    }

    /// Read a file the system handed over, receive it, and let go of the system's copy.
    @discardableResult
    func open(_ url: URL) -> Result<Receipt, Refusal> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            Self.discardInboxCopy(url)
        }
        // Refused by size before reading, so a huge file is never pulled into memory.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= LearningBundle.maximumBytes else {
            return finish(.failure(.bundle(.tooLarge(bytes: size))))
        }
        guard let data = try? Data(contentsOf: url) else { return finish(.failure(.unreadable)) }
        return receive(data, fileName: url.lastPathComponent)
    }

    /// Receive a bundle's bytes. Candidates are imported for review on a reviewer device;
    /// decisions are staged. Nothing is approved and nothing is published here.
    @discardableResult
    func receive(_ data: Data, fileName: String? = nil) -> Result<Receipt, Refusal> {
        if hipaaMode() { return finish(.failure(.hipaa)) }
        let decoded: LearningBundle.Decoded
        switch LearningBundle.decode(data) {
        case .failure(let refusal): return finish(.failure(.bundle(refusal)))
        case .success(let value): decoded = value
        }
        switch decoded.bundle.direction {
        case .candidates:
            return finish(importCandidates(decoded))
        case .decisions:
            if entries.bundleLedger.isOlder(decoded.bundle) { return finish(.failure(.bundle(.reordered))) }
            let next = Staged(bundle: decoded.bundle, redactionsOnIntake: decoded.redactionsOnIntake,
                              fileName: fileName, receivedAt: clock())
            staged = next
            return finish(.success(.staged(pending(for: next))))
        }
    }

    private func importCandidates(_ decoded: LearningBundle.Decoded) -> Result<Receipt, Refusal> {
        guard isReviewerDevice() else { return .failure(.notAReviewerDevice) }
        if let reason = entitlementRefusal() { return .failure(.notEntitled(reason)) }
        var holdings = LearningBundleMerge.Holdings(candidates: candidates.candidates, entries: entries.entries)
        var report = LearningBundleMerge.Report()
        LearningBundleMerge.mergeCandidates(decoded.bundle.candidates, into: &holdings,
                                            note: LearningBundleMerge.importNote(for: decoded.bundle),
                                            report: &report)
        for id in report.candidatesAdded + report.candidatesReplaced {
            guard let candidate = holdings.candidates.first(where: { $0.id == id }) else { continue }
            if self.candidates.candidate(id: id) == nil { self.candidates.add(candidate) } else { self.candidates.update(candidate) }
        }
        return .success(.imported(report, redactionsOnIntake: decoded.redactionsOnIntake))
    }

    // MARK: - Accepting

    /// Apply the named entries and retractions (by entry id) and statuses (by candidate id) from
    /// the staged bundle. Whatever is not named stays waiting; nothing named that is not in it is
    /// applied, and naming one refuses the whole request.
    @discardableResult
    func accept(entryIDs: Set<String>, candidateIDs: Set<String> = []) -> Result<LearningBundleMerge.Report, Refusal> {
        guard let current = staged else { return .failure(.nothingStaged) }
        if hipaaMode() { return .failure(.hipaa) }
        let bundle = current.bundle
        let knownEntries = Set(bundle.entries.map(\.entryID) + bundle.retracted.map(\.entryID))
        let knownCandidates = Set(bundle.statuses.map(\.candidateID))
        let unknown = entryIDs.subtracting(knownEntries).union(candidateIDs.subtracting(knownCandidates))
        guard unknown.isEmpty else { return .failure(.unknownItems(unknown.sorted())) }
        // Accepting nothing applies nothing, and does not count the bundle as applied.
        guard !entryIDs.isEmpty || !candidateIDs.isEmpty else { return .success(LearningBundleMerge.Report()) }

        // A retraction is accepted on any licence; an entry or a status needs the capability.
        let entryWanted = bundle.entries.contains { entryIDs.contains($0.entryID) }
        if (entryWanted || !candidateIDs.isEmpty), let reason = entitlementRefusal() {
            return .failure(.notEntitled(reason))
        }

        let accepted = bundle.selecting(entryIDs: entryIDs, candidateIDs: candidateIDs)
        let report = apply(accepted)

        // The bundle counts as applied once any of it is, so an older one is refused from now on.
        var ledger = entries.bundleLedger
        ledger.advance(for: bundle)
        entries.updateLedger(ledger)

        var remaining = bundle
        remaining.entries.removeAll { entryIDs.contains($0.entryID) }
        remaining.retracted.removeAll { entryIDs.contains($0.entryID) }
        remaining.statuses.removeAll { candidateIDs.contains($0.candidateID) }
        staged = remaining.isEmpty ? nil
            : Staged(bundle: remaining, redactionsOnIntake: current.redactionsOnIntake,
                     fileName: current.fileName, receivedAt: current.receivedAt)
        return .success(report)
    }

    /// Everything in the staged bundle.
    @discardableResult
    func acceptAll() -> Result<LearningBundleMerge.Report, Refusal> {
        guard let bundle = staged?.bundle else { return .failure(.nothingStaged) }
        return accept(entryIDs: Set(bundle.entries.map(\.entryID) + bundle.retracted.map(\.entryID)),
                      candidateIDs: Set(bundle.statuses.map(\.candidateID)))
    }

    /// Drop the staged bundle. Nothing from it was written anywhere, so nothing is left behind.
    func discard() {
        staged = nil
    }

    // MARK: - Applying

    /// Merge an accepted part into the stores, bring the corpus in line for every entry that
    /// changed, and tell each of this phone's own candidates' jobs what became of them.
    private func apply(_ accepted: LearningBundle) -> LearningBundleMerge.Report {
        let before = LearningBundleMerge.Holdings(candidates: candidates.candidates, entries: entries.entries,
                                                  tombstones: entries.bundleLedger.tombstones)
        let (after, report) = LearningBundleMerge.apply(accepted, to: before,
                                                        importedFrom: LearningBundleMerge.importNote(for: accepted))
        for id in report.entriesChanged {
            guard let entry = after.entries.first(where: { $0.id == id }) else { continue }
            entries.upsert(entry)
            if let documentStore { LearningCorpus.publish(entry, vaults: vaults(), store: documentStore) }
        }
        if after.tombstones != before.tombstones {
            var ledger = entries.bundleLedger
            ledger.tombstones = after.tombstones
            entries.updateLedger(ledger)
        }
        // Statuses first, then whether an entry made from each of this phone's candidates answers.
        var touched = Set(report.statusesApplied)
        for id in report.statusesApplied {
            guard let candidate = after.candidates.first(where: { $0.id == id }) else { continue }
            candidates.update(candidate)
        }
        let changedEntries = Set(report.entriesChanged)
        for candidate in candidates.candidates where candidate.isLocal {
            guard let entryID = candidate.entryID ?? after.entries.first(where: { $0.candidateID == candidate.id })?.id,
                  changedEntries.contains(entryID) || touched.contains(candidate.id) else { continue }
            touched.insert(candidate.id)
        }
        for id in touched.sorted() {
            guard let candidate = candidates.candidate(id: id), candidate.isLocal else { continue }
            recordStatus(candidate, inUse(candidate))
        }
        return report
    }

    /// Whether an approved entry made from (or merged with) this candidate answers on this phone.
    func inUse(_ candidate: LearningCandidate) -> Bool {
        guard candidate.status == .approved || candidate.status == .merged else { return false }
        let entry = candidate.entryID.flatMap(entries.entry(id:))
            ?? entries.entries.first { $0.candidateID == candidate.id }
        return entry?.isLive ?? false
    }

    // MARK: - Parts

    private func entitlementRefusal() -> String? {
        switch capability() {
        case .granted: return nil
        case .notIncluded: return FieldAssistPaywallCopy.teamLearningsBundleNotIncluded
        case .denied(.expired(_)): return FieldAssistPaywallCopy.teamLearningsBundleLapsed
        case .denied(.unverifiableLicense): return FieldAssistPaywallCopy.unverifiable
        case .denied(.noEvidence): return FieldAssistPaywallCopy.teamLearningsBundleLocked
        }
    }

    private func pending(for staged: Staged) -> Pending {
        let bundle = staged.bundle
        var result = Pending(redactionsOnIntake: staged.redactionsOnIntake)
        for wire in bundle.entries {
            let arriving = wire.entry()
            let change: Pending.Change
            if let held = entries.entry(id: wire.entryID) {
                if held.retractedAt != nil {
                    change = .retractedHere
                } else {
                    change = LearningBundleMerge.merged(held, with: arriving) == held ? .unchanged : .update
                }
            } else {
                change = .new
            }
            result.entries.append(.init(entryID: wire.entryID, citationName: arriving.citationName,
                                        text: LearningCorpus.documentText(arriving), wire: wire, change: change))
        }
        for status in bundle.statuses {
            let ours = candidates.candidate(id: status.candidateID)?.isLocal ?? false
            result.statuses.append(.init(candidateID: status.candidateID, decision: status.status,
                                         reason: status.reason, isOurs: ours))
        }
        for retraction in bundle.retracted {
            result.retractions.append(.init(entryID: retraction.entryID, reason: retraction.reason,
                                            isHeld: entries.entry(id: retraction.entryID) != nil))
        }
        return result
    }

    private func finish(_ result: Result<Receipt, Refusal>) -> Result<Receipt, Refusal> {
        switch result {
        case .failure(let refusal): lastMessage = refusal.message
        case .success(.imported(let report, _)):
            let count = report.candidatesAdded.count + report.candidatesReplaced.count
            lastMessage = "\(count) team learning\(count == 1 ? "" : "s") added for review."
        case .success(.staged(let pending)):
            lastMessage = "A team-learning file is waiting: \(pending.entries.count) entr\(pending.entries.count == 1 ? "y" : "ies"), "
                + "\(pending.retractions.count) retraction\(pending.retractions.count == 1 ? "" : "s"). Nothing is used until you accept it."
        }
        return result
    }

    /// The system's inbox copy of an opened file goes as soon as it is read, as a job file's does.
    private static func discardInboxCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
