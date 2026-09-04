import Foundation

/// The import sheet's state machine: repository text → parsed reference → resolved offer → chosen
/// file → licence → fit verdict → confirmed download
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "a custom import sheet with repository
/// parser, file/quant selection, license acceptance, and final download confirmation").
///
/// It is a separate object from the sheet for one reason: every refusal in this flow is a typed
/// value with copy written for a person — `LocalModelImportRejection` for the string,
/// `LocalModelImportFault` for what the repository turned out to contain — and a view that
/// re-words them is a view that eventually softens one. Here the messages are passed through
/// **verbatim**, and a test can prove it without a screenshot.
///
/// Every dependency is injected: the planner's fetcher, the fit report, and the download. The whole
/// flow therefore runs headlessly against fixtures with no network anywhere.
@MainActor
final class LocalModelImportController: ObservableObject {

    /// Where the sheet is. `failed` carries copy that is already user-ready.
    enum Stage: Equatable {
        /// Waiting for a repository.
        case entry
        /// Talking to the repository.
        case resolving
        /// The repository resolved; a file has to be chosen (or the curated default confirmed).
        case choosing
        /// Everything is chosen; the fit verdict and the licence are on screen.
        case confirming
        /// The download has been handed to the pipeline.
        case started
        case failed(String)
    }

    // MARK: - Inputs

    @Published var repositoryText: String = ""
    @Published var licenceAccepted: Bool = false
    /// The chosen weights candidate's id, within the offer.
    @Published var selectedCandidateID: String?

    // MARK: - Derived state

    @Published private(set) var stage: Stage = .entry
    @Published private(set) var offer: LocalModelImportOffer?
    @Published private(set) var descriptor: LocalModelDescriptor?
    @Published private(set) var fit: LocalModelFitReport?

    private let planner: LocalModelImportPlanner
    private let makeFit: (LocalModelDescriptor, String?) -> LocalModelFitReport
    private let startDownload: (LocalModelDescriptor, String?) async -> Void

    init(planner: LocalModelImportPlanner,
         makeFit: @escaping (LocalModelDescriptor, String?) -> LocalModelFitReport,
         startDownload: @escaping (LocalModelDescriptor, String?) async -> Void) {
        self.planner = planner
        self.makeFit = makeFit
        self.startDownload = startDownload
    }

    /// The production wiring: the live repository client, and the acquisition object's own fit
    /// reading and download call.
    convenience init(acquisition: LocalModelAcquisition) {
        self.init(planner: LocalModelImportPlanner(fetcher: LocalModelRepositoryClient()),
                  makeFit: { [weak acquisition] descriptor, accepted in
                      acquisition?.fitReport(for: descriptor, acceptedLicenseRevision: accepted)
                          ?? LocalModelFitReport.make(.init(descriptor: descriptor,
                                                            availableStorageBytes: nil,
                                                            availableProcessBytes: 0,
                                                            acceptedLicenseRevision: accepted))
                  },
                  startDownload: { [weak acquisition] descriptor, accepted in
                      await acquisition?.startDownload(descriptor: descriptor,
                                                       origin: .repositoryImport,
                                                       acceptedLicenseRevision: accepted)
                  })
    }

    // MARK: - Step 1: parse and resolve

    /// Parse the typed reference and, if it is well-formed, resolve the repository.
    ///
    /// The parse refusal is shown exactly as `LocalModelRepositoryReference` wrote it. Those
    /// sentences deliberately never echo the input — a rejection message is the most convenient
    /// place to leak whatever was pasted into it — so rewording them here would undo that as well
    /// as losing the rule they name.
    func resolve() async {
        offer = nil
        descriptor = nil
        fit = nil
        selectedCandidateID = nil
        licenceAccepted = false

        switch LocalModelRepositoryReference.parse(repositoryText) {
        case .failure(let rejection):
            stage = .failed(rejection.localizedMessage)
            // The case name, never the payload: an import rejection's associated value is the
            // host or scheme the user typed.
            PrivacyLog.localModel(.downloadFailed,
                                  detail: PrivacyToken.caseName(of: rejection))
            return
        case .success(let reference):
            stage = .resolving
            do {
                let resolved = try await planner.offer(for: reference)
                offer = resolved
                selectedCandidateID = resolved.defaultSelection?.id
                stage = .choosing
                if resolved.defaultSelection != nil { prepareConfirmation() }
            } catch let fault as LocalModelImportFault {
                stage = .failed(fault.localizedMessage)
            } catch {
                // Transport and decoding faults collapse to one sentence: the specific HTTP status
                // of a repository lookup is not something a person can act on.
                stage = .failed("That repository couldn't be read. Check the address and your "
                                    + "connection, then try again.")
            }
        }
    }

    // MARK: - Step 2: choose a file

    var weightsCandidates: [LocalModelImportCandidate] { offer?.weights ?? [] }
    var projectorCandidates: [LocalModelImportCandidate] { offer?.projectors ?? [] }

    var selectedCandidate: LocalModelImportCandidate? {
        guard let id = selectedCandidateID else { return nil }
        return offer?.weights.first { $0.id == id }
    }

    func choose(_ candidateID: String) {
        selectedCandidateID = candidateID
        prepareConfirmation()
    }

    // MARK: - Step 3: confirmation

    /// Build the descriptor and its fit report for the chosen candidate.
    ///
    /// Recomputed whenever the licence acceptance changes, because acceptance is one of the fit
    /// report's *blockers* — a consent screen whose action stays disabled after the box is ticked
    /// is a screen nobody can finish.
    func prepareConfirmation() {
        guard let offer, let candidate = selectedCandidate else {
            descriptor = nil
            fit = nil
            return
        }
        guard candidate.isInstallable else {
            stage = .failed(LocalModelImportFault.noVerifiableFiles.localizedMessage)
            return
        }
        do {
            let built = try LocalModelImportPlanner.descriptor(for: candidate, in: offer)
            descriptor = built
            fit = makeFit(built, acceptedLicenseRevision)
            stage = .confirming
        } catch let fault as LocalModelImportFault {
            stage = .failed(fault.localizedMessage)
        } catch {
            stage = .failed("That file couldn't be prepared for download.")
        }
    }

    /// The licence revision to record, or nil when nothing has been accepted. An offer's licence
    /// revision is the repository revision it was read at, so accepting is accepting *those* terms.
    var acceptedLicenseRevision: String? {
        guard licenceAccepted else { return nil }
        return offer?.license.revision ?? offer?.revision
    }

    var requiresLicenceAcceptance: Bool { offer?.license.requiresAcceptance ?? false }

    /// Re-derive the fit after the licence toggle moves.
    func licenceAcceptanceChanged() {
        guard descriptor != nil else { return }
        prepareConfirmation()
    }

    /// Whether the confirm action is enabled. **Blockers disable; warnings permit** — the rule is
    /// the fit report's, and this reads it rather than reproducing it.
    var canDownload: Bool {
        guard case .confirming = stage else { return false }
        return fit?.canInstall == true
    }

    /// The fit report, in the shape the sheet renders.
    var fitPresentation: LocalModelPresentation.FitPresentation? {
        fit.map(LocalModelPresentation.present)
    }

    // MARK: - Step 4: download

    func confirm() async {
        guard canDownload, let descriptor else { return }
        stage = .started
        await startDownload(descriptor, acceptedLicenseRevision)
    }

    /// Back out of the confirmation to the file list, without losing the resolved offer.
    func backToChoosing() {
        descriptor = nil
        fit = nil
        stage = .choosing
    }

    /// Start over from the text field.
    func reset() {
        offer = nil
        descriptor = nil
        fit = nil
        selectedCandidateID = nil
        licenceAccepted = false
        stage = .entry
    }

    // MARK: - Copy

    /// The candidate list's secondary line: what it is and whether it can be installed at all.
    static func candidateSubtitle(_ candidate: LocalModelImportCandidate) -> String {
        var parts: [String] = [LocalModelPresentation.formatBytes(candidate.byteCount)]
        if candidate.files.count > 1 { parts.append("\(candidate.files.count) files") }
        if !candidate.isInstallable { parts.append("no checksum — can't be verified") }
        return parts.joined(separator: " · ")
    }

    static func candidateSpokenLabel(_ candidate: LocalModelImportCandidate) -> String {
        var sentence = candidate.quantizationLabel
            .map { "\(LocalModelPresentation.spellOut($0)) quantization" }
            ?? candidate.id
        sentence += ", \(LocalModelPresentation.formatBytes(candidate.byteCount))"
        if candidate.files.count > 1 { sentence += ", \(candidate.files.count) files" }
        if !candidate.isInstallable {
            sentence += ". This file publishes no checksum, so it can't be downloaded."
        }
        return sentence
    }
}
