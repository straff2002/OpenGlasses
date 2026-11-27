import Foundation

/// A workbook on its way into the van's stock (Plan IH §6).
///
/// Reading a workbook changes nothing. It raises a review — what would be counted, added and
/// changed, what is missing, what was refused — and the one button on that review is the write.
/// Whichever way the file arrived, from Mail or from the Van Stock screen, it comes through here.
@MainActor
final class VanStockImportService: ObservableObject {

    static let shared = VanStockImportService()

    /// Why a file was not read into a review.
    enum Refusal: Equatable {
        case fieldAssistOff
        case switchedOffByOrganisation
        case listUnreadable
        case fileUnreadable
        case workbook(XLSXReader.Failure)
        case noRecognisableHeader
        /// It was read, and applying it would change nothing.
        case nothingToChange
        /// A business's own stock system holds the count (Plan MM P3/P4): the phone's list is the
        /// previous list, so a workbook is not loaded into it. Carries the system's name.
        case heldBySystem(String)
        /// A clinic's list was offered a sheet with a column that may hold patient details (Plan
        /// NJ §1). Carries the headings, never a value under them. Nothing was read into a review.
        case patientColumns([String])

        /// "Stock is kept in <system>, so this list was kept as the previous list and not loaded."
        static func heldBySystemSentence(_ system: String) -> String {
            "Stock is kept in \(system), so this list was kept as the previous list and not loaded."
        }
    }

    enum Stage: Equatable {
        case idle
        case refused(Refusal)
        case reviewing(VanStockSheet.Proposal, fileName: String)
    }

    /// What a workbook under review may be applied as (Plan IH P5).
    enum Mode: Equatable {
        /// Corrections to this van's list: the ordinary import.
        case corrections
        /// The whole truth about a van: its list replaces the phone's.
        case takeover
        /// Base's standard load: standards only, no level changes.
        case baseline
    }

    /// The same workbook read as a van to take over. Nil when it does not say which van it is.
    @Published private(set) var takeover: VanStockHandover.Takeover?
    /// The same workbook read as base's baseline. Nil when it would change no standard.
    @Published private(set) var baseline: [VanStockHandover.BaselineChange]?

    @Published private(set) var stage: Stage = .idle

    private let store: VanStockStore
    private let service: VanStockService
    private let isAllowed: () -> Refusal?

    init(store: VanStockStore? = nil, service: VanStockService? = nil, isAllowed: (() -> Refusal?)? = nil) {
        self.store = store ?? .shared
        self.service = service ?? .shared
        self.isAllowed = isAllowed ?? {
            if !Config.fieldAssistActive { return .fieldAssistOff }
            if Config.organizationForbidsVanStock { return .switchedOffByOrganisation }
            return nil
        }
    }

    /// Read a file the system handed over, then let go of the system's copy.
    func open(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Refuse by size before reading, so a huge file is never pulled into memory.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= XLSXReader.maximumFileBytes else {
            stage = .refused(.workbook(.tooLarge))
            Self.discardInboxCopy(url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            stage = .refused(.fileUnreadable)
            return
        }
        handle(data: data, fileName: url.lastPathComponent)
        Self.discardInboxCopy(url)
    }

    /// The pure half of `open`, for a file's bytes and name.
    func handle(data: Data, fileName: String) {
        if let refusal = isAllowed() {
            stage = .refused(refusal)
            return
        }
        // Said, never skipped silently: the system holds the count, so nothing is loaded.
        if let system = service.systemName {
            stage = .refused(.heldBySystem(system))
            return
        }
        guard !store.isUnreadable else {
            stage = .refused(.listUnreadable)
            return
        }
        takeover = nil
        baseline = nil
        let sheets: [XLSXReader.Sheet]
        switch XLSXReader.read(data) {
        case .failure(let failure):
            stage = .refused(.workbook(failure))
            return
        case .success(let read):
            sheets = read
        }
        // Fail closed for a clinic's list (Plan NJ §1): a column about a patient refuses the whole
        // sheet, as a correction, a takeover or a baseline alike. A van's list reads it as before.
        if service.isClinical {
            let patient = ClinicalStockInboundGuard.patientHeadings(in: sheets)
            if !patient.isEmpty {
                stage = .refused(.patientColumns(patient))
                return
            }
        }
        switch VanStockSheet.proposal(from: sheets, log: store.log) {
        case .failure(.workbook(let failure)):
            stage = .refused(.workbook(failure))
        case .failure(.noRecognisableHeader):
            stage = .refused(.noRecognisableHeader)
        case .success(let proposal):
            // A workbook that names its van can be taken over; one with standards can be applied
            // as base's baseline. Either is offered beside the ordinary import, never instead.
            if case .success(let read) = service.takeover(from: sheets), read.van != nil { takeover = read }
            if case .success(let changes) = VanStockHandover.baseline(from: sheets, log: store.log),
               !changes.isEmpty { baseline = changes }
            let nothing = proposal.changesNothing && proposal.refusals.isEmpty && proposal.missing.isEmpty
            stage = nothing && takeover == nil && baseline == nil
                ? .refused(.nothingToChange)
                : .reviewing(proposal, fileName: fileName)
        }
    }

    /// Which way of applying the workbook is offered first: a workbook from another van, or onto a
    /// phone with no list, is a takeover; anything else is a correction.
    var suggestedMode: Mode {
        guard let takeover else { return .corrections }
        return store.log.isEmpty || takeover.van?.id != store.van?.id ? .takeover : .corrections
    }

    /// Whether the workbook under review is older than the phone's own latest entry for the same
    /// van — a handover that is not the newest word on it.
    var takeoverIsStale: Bool {
        guard let takeover, let exported = takeover.exportedAt, takeover.van?.id == store.van?.id,
              let latest = store.log.movements.last?.at else { return false }
        return latest >= exported.addingTimeInterval(1)
    }

    /// Take the van over: the workbook's list replaces the phone's, and the review closes.
    @discardableResult
    func applyTakeover() -> Bool {
        guard case .reviewing = stage, let takeover else { return false }
        service.takeOver(takeover)
        dismiss()
        return true
    }

    /// Apply base's baseline: standards only, as one batch.
    @discardableResult
    func applyBaseline(takingBaseFigure: Set<String> = []) -> Bool {
        guard case .reviewing = stage, let baseline else { return false }
        let applied = service.apply(baseline: baseline, takingBaseFigure: takingBaseFigure)
        dismiss()
        return applied
    }

    /// The one write: apply what is being reviewed, as a single batch, and close the review.
    @discardableResult
    func apply(keepingPhoneFigure: Set<String> = []) -> Bool {
        guard case .reviewing(let proposal, _) = stage else { return false }
        let applied = service.apply(proposal, keepingPhoneFigure: keepingPhoneFigure)
        dismiss()
        return applied
    }

    func dismiss() {
        stage = .idle
        takeover = nil
        baseline = nil
    }

    /// A file opened from another app arrives as a copy in the app's Inbox; it has been read, so
    /// it goes. A file picked in place is somebody's own and is left alone.
    private static func discardInboxCopy(_ url: URL) {
        guard url.deletingLastPathComponent().lastPathComponent == "Inbox",
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              url.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
