import Foundation

/// Which kind of recording each surface starts, and how a kept recording reads (Plan IM P4).
///
/// Pure, so the phone's page, the Jobs list, Field Assist settings and the car cannot disagree
/// about whether a recording is a case or a site, or about where a site recording goes: it is
/// always kept on the phone, never filed on an open job.
enum ExperienceRecordingEntry {

    /// The kind the phone's recorder page shows and starts: the one being recorded while a session
    /// runs, else the one the technician picked.
    static func kind(selected: ExperienceRecording.Kind, recorderBusy: Bool,
                     recording: ExperienceRecording.Kind) -> ExperienceRecording.Kind {
        recorderBusy ? recording : selected
    }

    /// The kind a Jobs-list route opens the recorder page on, or nil for a route that isn't the
    /// recorder.
    static func kind(for route: JobRoute) -> ExperienceRecording.Kind? {
        switch route {
        case .recordExperience: return .experience
        case .recordSite: return .site
        default: return nil
        }
    }

    /// The kind a car row starts, or nil for a row that starts no recording.
    static func kind(for selection: CarPlayJobsList.Selection) -> ExperienceRecording.Kind? {
        switch selection {
        case .recordExperience: return .experience
        case .recordSite: return .site
        default: return nil
        }
    }

    /// Whether a recording made now files on the open job: only a case, and only with a job open.
    /// A site recording drafts a site document, never a learning, so it is always kept here.
    static func filesOnOpenJob(kind: ExperienceRecording.Kind, jobOpen: Bool) -> Bool {
        kind == .experience && jobOpen
    }

    /// The button that starts a recording of this kind.
    static func startTitle(_ kind: ExperienceRecording.Kind) -> String {
        switch kind {
        case .experience: return String(localized: "Record experience")
        case .site: return ExperienceRecorderCopy.siteTitle
        }
    }

    /// The word a kept recording's row leads with: "Site" for a site, nothing for a case (the
    /// kind every recording before P4 was).
    static func kindLabel(_ kind: ExperienceRecording.Kind) -> String? {
        switch kind {
        case .experience: return nil
        case .site: return String(localized: "Site")
        }
    }

    /// A kept recording's second line: its kind (a site), its length and where it is.
    static func rowCaption(_ recording: ExperienceRecording) -> String {
        ([kindLabel(recording.kind)].compactMap { $0 } + [recording.formattedDuration, recording.status.label])
            .joined(separator: " · ")
    }

    /// The kept recording's page title.
    static func detailTitle(_ kind: ExperienceRecording.Kind) -> String {
        switch kind {
        case .experience: return String(localized: "Recording")
        case .site: return String(localized: "Site recording")
        }
    }
}

/// Whether a kept recording offers "Draft site document" (Plan IM P4). Pure. The drafter keeps
/// these gates itself (`SiteRecordingDrafter`); this decides only what the page shows.
enum SiteDraftOffer: Equatable {
    /// Nothing about a site document: a case, or Medical Compliance.
    case none
    /// A site recording on a phone that isn't a reviewer's: a line saying so, no button.
    case reviewerOnly
    /// A site recording on a reviewer's phone: the button.
    case available

    static func offer(for kind: ExperienceRecording.Kind, reviewerDevice: Bool, medicalCompliance: Bool) -> SiteDraftOffer {
        guard kind == .site, !medicalCompliance else { return .none }
        return reviewerDevice ? .available : .reviewerOnly
    }

    @MainActor
    static func current(for kind: ExperienceRecording.Kind) -> SiteDraftOffer {
        offer(for: kind, reviewerDevice: Config.teamLearningReviewerDevice, medicalCompliance: Config.hipaaMode)
    }

    static var reviewerOnlyLine: String {
        String(localized: "A reviewer's phone drafts the site document from this recording.")
    }
}

/// What a drafted site document shows on the phone (Plan IM P4): read-only, exactly as validated.
struct SiteDraftSummary: Equatable {
    struct Unit: Equatable {
        let model: String
        let serial: String?
        let label: String?
        /// False for a unit the vault has no section for (a thermostat, say).
        let isCovered: Bool
    }

    let name: String
    let location: String?
    let notes: String?
    let units: [Unit]
    /// Every other text the document holds — connections, controls, integrations, settings and
    /// faults — in the document's order, verbatim.
    let details: [String]

    init(_ document: SiteSystemDocument) {
        name = document.name
        location = document.locationLabel
        notes = document.notes
        units = document.units.map { Unit(model: $0.model, serial: $0.serial, label: $0.label, isCovered: $0.isCovered) }
        let shownAbove: Set<String> = ["name", "location_label", "notes"]
        details = SiteRecordingDraftRules.textMembers(of: document)
            .filter { !shownAbove.contains($0.path) && !($0.path.hasPrefix("units[") && $0.path.hasSuffix("].label")) }
            .map(\.text)
    }
}

/// "Draft site document" on a reviewer's phone (Plan IM P4): runs `SiteRecordingDrafter` on a kept
/// site recording and holds the result for the page. It stores nothing and installs nothing: a
/// drafted document is shown and can be shared as its file, for whoever builds the vault.
@MainActor
final class SiteDraftReviewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case drafting
        case drafted(SiteRecordingDraft)
        /// Nothing drafted: what the reviewer is told, and the reasons, verbatim.
        case refused(message: String, reasons: [String])
    }

    @Published private(set) var state: State = .idle
    /// The drafted document's file, written for the share sheet; nil until drafted, or when it
    /// couldn't be written.
    @Published private(set) var shareURL: URL?

    private let drafter: SiteRecordingDrafter
    /// The model index of an installed vault, by id; nil when it isn't on this phone.
    private let index: @MainActor (String) -> VaultModelIndex?
    private let shareFolder: URL

    init(drafter: SiteRecordingDrafter, index: @escaping @MainActor (String) -> VaultModelIndex?,
         shareFolder: URL = SiteDraftReviewModel.shareFolder()) {
        self.drafter = drafter
        self.index = index
        self.shareFolder = shareFolder
    }

    /// The app's: the configured provider through P2's seam, and the vault the recording was made in.
    static func live() -> SiteDraftReviewModel {
        SiteDraftReviewModel(drafter: .live(llm: AppStateProvider.shared?.llmService), index: { id in
            guard let manifest = VaultRegistry.shared.allManifests.first(where: { $0.id == id }) else { return nil }
            return VaultModelIndex(store: VaultRegistry.shared.store(for: manifest))
        })
    }

    static var vaultMissing: String {
        String(localized: "The vault this site was recorded in isn't on this phone, so a site document can't be checked against it.")
    }

    func draft(_ recording: ExperienceRecording) async {
        guard state != .drafting else { return }
        shareURL = nil
        guard let index = index(recording.vaultId) else {
            state = .refused(message: Self.vaultMissing, reasons: [])
            return
        }
        state = .drafting
        switch await drafter.draft(recording, index: index) {
        case .success(let draft):
            shareURL = try? Self.shareFile(draft, in: shareFolder)
            state = .drafted(draft)
        case .failure(let refusal):
            state = .refused(message: refusal.message, reasons: Self.reasons(refusal))
        }
    }

    /// The reasons under the message: HV's issues as its validator wrote them, or the member the
    /// rules stopped at.
    static func reasons(_ refusal: SiteRecordingDraftValidator.Refusal) -> [String] {
        switch refusal {
        case .siteDocument(let issues): return issues
        case .stampedMember(let member):
            return [String(localized: "Not taken from speech: \(member)")]
        case .notSaid(let member):
            return [String(localized: "Not said in the recording: \(member)")]
        case .unsupported(let member):
            return [String(localized: "Words not said in the recording: \(member)")]
        case .notReviewerDevice, .medicalCompliance, .notASiteRecording, .emptyTranscript, .noAnswer, .malformed:
            return []
        }
    }

    /// The shared file's name: `site-<recording id>.json`, the name it takes in the vault's `sites/`.
    nonisolated static func shareFileName(_ draft: SiteRecordingDraft) -> String {
        (draft.path as NSString).lastPathComponent
    }

    /// The draft written as its file in `folder` (the app's temporary folder, never backed up), for
    /// the share sheet. The bytes are the validated ones, unchanged.
    static func shareFile(_ draft: SiteRecordingDraft, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(shareFileName(draft))
        try draft.data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static func shareFolder(fileManager: FileManager = .default) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent("SiteDocumentDrafts", isDirectory: true)
    }

    static var shareUnavailable: String {
        String(localized: "The file couldn't be prepared to share. Draft it again.")
    }

    static var shareFooter: String {
        String(localized: "Whoever builds your vault can add this file to its site documents. Nothing is added to the vault on this phone.")
    }
}
