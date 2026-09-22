import Foundation

/// What the evidence review draws, and what it hands to the share sheet (Plan FO P2a).
///
/// The counterpart of `EvidenceRenderPlan`: that one decides what the *work order* prints, this one
/// decides what the *technician* sees while choosing. They are separate because they answer
/// different questions — the report shows only what was selected, Fault first; the review has to
/// show everything, in the order it was taken, or the technician cannot find the picture they mean.
///
/// A plain struct with no services in it, so every one of those decisions is provable without a
/// vault, a session directory full of JPEGs, or SwiftUI.
struct EvidenceReviewModel: Equatable {

    /// One thumbnail.
    struct Row: Identifiable, Equatable {
        let item: JobMediaItem
        /// The task it was recorded against, or nil for the job itself.
        let taskTitle: String?
        var id: String { item.id }

        /// What VoiceOver reads, given the decision that stands against it right now.
        func spoken(included: Bool, role: EvidenceSelection.Role?) -> String {
            item.spoken(taskTitle: taskTitle, included: included, role: role)
        }
    }

    /// The pictures recorded against one task, or against the job.
    struct Group: Identifiable, Equatable {
        /// The task id, or `Self.jobLevelId` for the job-level group.
        let id: String
        let title: String
        let rows: [Row]

        static let jobLevelId = "job"
    }

    /// Oldest first inside each group — **newest last**, so the picture a technician has just
    /// taken is the one at the end rather than somewhere in the middle of a grid.
    let groups: [Group]
    /// Where the files live, for the thumbnails and for the share sheet.
    let photosDirectory: URL
    /// What the recipient will see of anyone who happened to be standing there — and **which
    /// question that is** depends on whether the job is still open.
    let faceBlur: FaceBlur
    /// Every item, in capture order — what the voice walk steps through.
    let items: [JobMediaItem]

    /// The face-blur fact this screen is entitled to state.
    ///
    /// An open job and a finished one are asking different questions, and answering the second
    /// with the first is how a record ends up lying about itself. While the job is open, the
    /// app-wide setting is the right answer: it is what will apply to the next picture, and it can
    /// still be changed. Once the job is closed nothing about those files can change — the blur
    /// was applied at capture and the filtered copy is the only one kept — so the honest answer is
    /// what was recorded against the pictures themselves. The setting may well have been toggled
    /// since, and reading it there would tell the technician about today rather than about the
    /// photographs a customer is holding.
    enum FaceBlur: Equatable {
        /// An open job: the app-wide setting as it stands.
        case live(on: Bool)
        /// A finished job: what was actually applied, counted from the items' own `filterWasOn`.
        case asRecorded(blurred: Int, total: Int)

        /// Whether to draw the blur as in force. A finished job qualifies only when **every**
        /// picture was blurred — a job that is half and half is not "on", and the icon must not
        /// imply that it is.
        var isOn: Bool {
            switch self {
            case .live(let on): return on
            case .asRecorded(let blurred, let total): return total > 0 && blurred == total
            }
        }

        /// Count what a finished job's pictures actually carry.
        static func recorded(from items: [JobMediaItem]) -> FaceBlur {
            .asRecorded(blurred: items.filter(\.filterWasOn).count, total: items.count)
        }
    }

    init(items: [JobMediaItem], taskTitles: [(id: String, title: String)],
         photosDirectory: URL, faceBlur: FaceBlur) {
        self.items = items
        self.photosDirectory = photosDirectory
        self.faceBlur = faceBlur

        let sorted = items.sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
        let titles = Dictionary(taskTitles.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        var built: [Group] = []
        for task in taskTitles {
            let rows = sorted.filter { $0.taskId == task.id }
                .map { Row(item: $0, taskTitle: titles[task.id]) }
            if !rows.isEmpty { built.append(Group(id: task.id, title: task.title, rows: rows)) }
        }
        let known = Set(taskTitles.map(\.id))
        // The job-level group takes anything with no task, and anything whose task the record no
        // longer carries — the same rule the render plan follows, so the grid and the PDF can
        // never disagree about where a photograph belongs.
        let loose = sorted.filter { $0.taskId.map { !known.contains($0) } ?? true }
            .map { Row(item: $0, taskTitle: nil) }
        if !loose.isEmpty {
            built.append(Group(id: Group.jobLevelId, title: EvidenceRenderPlan.jobLevelTitle,
                               rows: loose))
        }
        self.groups = built
    }

    /// The open-job case, where the current setting is the right answer.
    init(items: [JobMediaItem], taskTitles: [(id: String, title: String)],
         photosDirectory: URL, faceBlurOn: Bool) {
        self.init(items: items, taskTitles: taskTitles, photosDirectory: photosDirectory,
                  faceBlur: .live(on: faceBlurOn))
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    // MARK: - Words

    /// Whether to draw the blur as in force.
    var faceBlurOn: Bool { faceBlur.isOn }

    /// "Face blur: On" — the plain statement the Job tab and the review both carry. A finished
    /// job says when it was true, because that is the only tense in which it still is.
    var faceBlurLine: String {
        switch faceBlur {
        case .live(let on):
            return on ? "Face blur: On" : "Face blur: Off"
        case .asRecorded(let blurred, let total):
            if total == 0 || blurred == 0 { return "Face blur: Off when these were taken" }
            if blurred == total { return "Face blur: On when these were taken" }
            return "Face blur: On for \(blurred) of \(total)"
        }
    }

    /// What that means for the pictures in front of the technician — and, while the job is open,
    /// where to change it. A finished job is offered no such link: there is nothing left to change
    /// about pictures that were filtered on their way to disk.
    var faceBlurDetail: String {
        switch faceBlur {
        case .live(true):
            return "Faces of anyone else in these pictures are blurred before they are saved, so "
                + "the blur cannot be undone here. Change it under Settings → Glasses & Privacy → "
                + "Hardware & Privacy."
        case .live(false):
            return "Faces in these pictures are not blurred. Turn it on under Settings → Glasses & "
                + "Privacy → Hardware & Privacy — it applies to pictures taken from then on."
        case .asRecorded(let blurred, let total):
            if total == 0 || blurred == 0 {
                return "Faces in these pictures were not blurred when they were taken, and that "
                    + "cannot be changed now — what was stored is what a recipient sees."
            }
            if blurred == total {
                return "Faces of anyone else were blurred before these pictures were saved, and "
                    + "that cannot be undone — the blurred copy is the only one kept."
            }
            return "\(blurred) of these \(total) pictures had faces blurred before they were "
                + "saved and the rest did not. Neither can be changed now."
        }
    }

    /// The label on an item captured while the blur was on.
    static let blurredItemLabel = "Captured with face blur"

    /// "3 of 7 photos will go with the report" — or "went with", once the job is closed and the
    /// report has already been made from them. The same tense rule as the face-blur line: a
    /// finished job describes what happened, not what is about to.
    func summary(for selection: EvidenceSelection) -> String {
        let chosen = selection.entries.filter(\.included).count
        let verb = isFinished ? "went with" : "will go with"
        guard count > 0 else { return "No photos were taken on this job." }
        guard chosen > 0 else { return "No photos \(verb) the report." }
        return "\(chosen) of \(count) photo\(count == 1 ? "" : "s") \(verb) the report."
    }

    /// Whether this is a record of a closed job rather than one still being worked on. Read off
    /// the face-blur case, because that is the same distinction: `.asRecorded` exists precisely
    /// when nothing about these files can change any more.
    private var isFinished: Bool {
        if case .asRecorded = faceBlur { return true }
        return false
    }

    // MARK: - Sharing

    /// The stored files for everything selected, in the order the report prints them.
    ///
    /// The **stored** files: already privacy-filtered, full size, exactly as they are on disk. The
    /// work order carries downscaled copies; this route is the one that does not, which is why it
    /// is a share sheet the technician taps rather than anything that sends by itself.
    func shareURLs(for selection: EvidenceSelection) -> [URL] {
        let known = Set(items.map(\.id))
        return selection.includedItemIds
            .filter { known.contains($0) }
            .map { photosDirectory.appendingPathComponent($0) }
    }

    /// The file for one item, for a thumbnail.
    func url(for itemId: String) -> URL { photosDirectory.appendingPathComponent(itemId) }
}
