import Foundation

/// The evidence the work order prints, grouped and ordered, decided without a PDF context.
///
/// The exporter used to print one text bullet per photo and needed no plan at all. Rendering the
/// pictures needs two orderings at once — by task, because that is how the record reads, and Fault
/// before Fix before unmarked, because that is the story the customer is being shown — and getting
/// them out of the drawing code is what makes "the PDF contains exactly the selected images, in
/// that order" something a headless test can state.
struct EvidenceRenderPlan: Equatable {

    /// One picture, with everything printed under it.
    struct Entry: Equatable {
        let item: JobMediaItem
        let role: EvidenceSelection.Role?
        let caption: String?

        /// The line under the image: the caption if there is one, otherwise the time alone.
        var captionLine: String {
            guard let caption, !caption.isEmpty else { return item.timeLabel }
            return "\(caption) — \(item.timeLabel)"
        }
    }

    /// The evidence recorded against one task, or against the job itself.
    struct Group: Equatable {
        /// Nil for the job-level group.
        let taskId: String?
        let title: String
        let entries: [Entry]
    }

    let groups: [Group]

    var isEmpty: Bool { groups.allSatisfy { $0.entries.isEmpty } }
    var entryCount: Int { groups.reduce(0) { $0 + $1.entries.count } }
    /// Pictures the report draws. Clips are named rather than drawn, so the image budget — which
    /// is decided from a count — must not see them (Plan FO P2b).
    var photoCount: Int { count(of: .photo) }
    var clipCount: Int { count(of: .clip) }

    private func count(of kind: JobMediaItem.Kind) -> Int {
        groups.reduce(0) { $0 + $1.entries.filter { $0.item.kind == kind }.count }
    }
    /// Every item the plan will draw, in the order it draws them.
    var itemIds: [String] { groups.flatMap { $0.entries.map(\.item.id) } }

    /// The heading the job-level group prints. Matches the read-back's own phrase, so the record
    /// and the pictures use one vocabulary.
    static let jobLevelTitle = "Against the job itself"

    /// Build the plan from the catalogue, the technician's selection, and the tasks in the order
    /// the record lists them.
    ///
    /// Only included items appear. An item the selection has never heard of does not appear either:
    /// a picture with no decision recorded against it has not been chosen, and "not chosen" is the
    /// only safe reading when what is at stake is a photograph leaving the device.
    static func make(items: [JobMediaItem],
                     selection: EvidenceSelection,
                     taskTitles: [(id: String, title: String)]) -> EvidenceRenderPlan {
        let itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let included = selection.entries.filter(\.included).filter { itemsById[$0.itemId] != nil }
        guard !included.isEmpty else { return EvidenceRenderPlan(groups: []) }

        func entries(where belongs: (JobMediaItem) -> Bool) -> [Entry] {
            let subset = included.filter { belongs(itemsById[$0.itemId]!) }
            return selection.renderOrdered(subset).map { entry in
                let item = itemsById[entry.itemId]!
                return Entry(item: item, role: entry.role, caption: entry.caption ?? item.caption)
            }
        }

        var groups: [Group] = []
        for task in taskTitles {
            let rows = entries { $0.taskId == task.id }
            if !rows.isEmpty { groups.append(Group(taskId: task.id, title: task.title, entries: rows)) }
        }
        // Everything that names no task, and anything naming a task the record no longer carries —
        // the evidence is still the technician's, and dropping it because its task was renamed away
        // would be the record quietly losing a photograph.
        let known = Set(taskTitles.map(\.id))
        let loose = entries { $0.taskId.map { !known.contains($0) } ?? true }
        if !loose.isEmpty {
            groups.append(Group(taskId: nil, title: jobLevelTitle, entries: loose))
        }
        return EvidenceRenderPlan(groups: groups)
    }
}
