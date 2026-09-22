import Foundation

/// What of the job's evidence goes out with the report, and in what order (Plan FO P2a).
///
/// The decision is the technician's and it is made once, at close, before anything is rendered or
/// sent. Three rules shape the type:
///
///  1. **Skipping is a real answer.** `reviewed` starts false and stays false when the technician
///     taps past the step. A selection that was never made must reproduce the text-only record the
///     app sent before any of this existed, so "nothing chosen" and "everything excluded" cannot be
///     the same value.
///  2. **Fault/Fix is optional.** It is never prompted and never required. A job with no marks at
///     all is an ordinary job, and the ordering rule has to degrade to "capture order" rather than
///     to an empty list.
///  3. **It is part of the record.** Persisted on the session and carried into `WorkRecord`, so a
///     re-send from a past job reproduces exactly the PDF that went out the first time rather than
///     a fresh guess at what the technician meant.
struct EvidenceSelection: Codable, Equatable {

    /// The two marks, and nothing else. A vocabulary that grew would turn an optional convenience
    /// into a taxonomy the technician has to learn.
    enum Role: String, Codable, CaseIterable {
        case fault
        case fix

        var label: String { self == .fault ? "Fault" : "Fix" }

        /// The heading the work order prints above the group.
        var heading: String { self == .fault ? "The fault" : "The fix" }
    }

    /// One item's fate.
    struct Entry: Codable, Equatable, Identifiable {
        let itemId: String
        /// Carried so the grid and the export can group by kind without holding the catalogue.
        /// Photos today; a clip is a second kind, not a second selection model (P2b).
        var kind: JobMediaItem.Kind
        var included: Bool
        var role: Role?
        /// The caption as it will be printed — the capture-time one until it is edited.
        var caption: String?
        /// Capture order, oldest first. Stable across re-sends; not the render order.
        var order: Int

        var id: String { itemId }

        init(itemId: String, kind: JobMediaItem.Kind = .photo, included: Bool,
             role: Role? = nil, caption: String? = nil, order: Int) {
            self.itemId = itemId
            self.kind = kind
            self.included = included
            self.role = role
            self.caption = caption
            self.order = order
        }

        enum CodingKeys: String, CodingKey {
            case itemId = "item_id"
            case kind, included, role, caption, order
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemId = try c.decode(String.self, forKey: .itemId)
            kind = (try? c.decodeIfPresent(JobMediaItem.Kind.self, forKey: .kind)).flatMap { $0 } ?? .photo
            included = try c.decodeIfPresent(Bool.self, forKey: .included) ?? false
            role = (try? c.decodeIfPresent(Role.self, forKey: .role)).flatMap { $0 }
            caption = try c.decodeIfPresent(String.self, forKey: .caption)
            order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        }
    }

    /// Whether the technician has actually been through the review step. **False means the report
    /// is the one the app has always sent** — text bullets, no pictures — not "an empty choice".
    var reviewed: Bool
    var entries: [Entry]

    init(reviewed: Bool = false, entries: [Entry] = []) {
        self.reviewed = reviewed
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey {
        case reviewed, entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviewed = try c.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    // MARK: - Building

    /// The selection the review step opens on: capture order, `photo_log` already ticked, every
    /// other route offered but not assumed.
    ///
    /// The default is the one place the *reason* a picture was taken is allowed to decide anything.
    /// A `photo_log` capture exists because the technician said "log this", so leaving it out would
    /// be the app second-guessing an instruction; a `capture_photo` or a library picture was taken
    /// for some other purpose and may be of a colleague's lunch. A **clip** is never ticked by
    /// default whatever asked for it — see `JobMediaItem.isIncludedByDefault`.
    static func proposed(for items: [JobMediaItem]) -> EvidenceSelection {
        EvidenceSelection(
            reviewed: false,
            entries: items.enumerated().map { index, item in
                Entry(itemId: item.id, kind: item.kind,
                      included: item.isIncludedByDefault,
                      caption: item.caption, order: index)
            })
    }

    /// Carry a stored selection forward over the job's current evidence.
    ///
    /// Evidence can arrive after a selection was proposed — the review step is open while the
    /// technician is still on site — and a stored selection read back from an older build may name
    /// files that are no longer there. Neither is an error: an item nobody has decided about takes
    /// the default, an entry with no item is dropped, and every decision already made survives.
    func reconciled(with items: [JobMediaItem]) -> EvidenceSelection {
        let byId = Dictionary(entries.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
        var next = EvidenceSelection(reviewed: reviewed, entries: [])
        for (index, item) in items.enumerated() {
            if var existing = byId[item.id] {
                existing.kind = item.kind
                existing.order = index
                next.entries.append(existing)
            } else {
                next.entries.append(Entry(itemId: item.id, kind: item.kind,
                                          included: item.isIncludedByDefault,
                                          caption: item.caption, order: index))
            }
        }
        return next
    }

    // MARK: - Reading

    func entry(for itemId: String) -> Entry? {
        entries.first { $0.itemId == itemId }
    }

    var includedCount: Int { entries.filter(\.included).count }

    /// Everything included of one kind, in render order — what the exporter draws and what the
    /// delivery budget has to find room for.
    func includedItemIds(kind: JobMediaItem.Kind) -> [String] {
        renderOrdered(entries.filter { $0.included && $0.kind == kind }).map(\.itemId)
    }

    /// Ids of everything going out, in **render** order: Fault, then Fix, then unmarked, each by
    /// capture order. This is what the work order prints and what the share sheet hands out, so
    /// there is one ordering rule rather than one per surface.
    var includedItemIds: [String] { renderOrdered(entries.filter(\.included)).map(\.itemId) }

    /// The same ordering applied to any subset — what a per-task group inside the report needs.
    func renderOrdered(_ subset: [Entry]) -> [Entry] {
        subset.sorted { left, right in
            let leftRank = Self.rank(left.role), rightRank = Self.rank(right.role)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.order != right.order { return left.order < right.order }
            return left.itemId < right.itemId
        }
    }

    /// Fault first, then Fix, then everything unmarked. Marking is optional, so "unmarked" is the
    /// ordinary case and sorts last rather than being treated as missing data.
    private static func rank(_ role: Role?) -> Int {
        switch role {
        case .fault: return 0
        case .fix: return 1
        case nil: return 2
        }
    }

    // MARK: - Editing

    mutating func setIncluded(_ included: Bool, for itemId: String) {
        guard let index = entries.firstIndex(where: { $0.itemId == itemId }) else { return }
        entries[index].included = included
    }

    /// Mark, or clear the mark by setting the same one twice — the grid's one tap per role.
    mutating func setRole(_ role: Role?, for itemId: String) {
        guard let index = entries.firstIndex(where: { $0.itemId == itemId }) else { return }
        entries[index].role = entries[index].role == role ? nil : role
        // A marked item is one the technician has just said is part of the story, so marking it
        // includes it. Un-marking leaves the inclusion alone: they may still want the picture.
        if entries[index].role != nil { entries[index].included = true }
    }

    /// An empty caption is no caption — a blank line under a photo says nothing and prints badly.
    mutating func setCaption(_ caption: String?, for itemId: String) {
        guard let index = entries.firstIndex(where: { $0.itemId == itemId }) else { return }
        let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].caption = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    mutating func includeAll() {
        for index in entries.indices { entries[index].included = true }
    }

    mutating func excludeAll() {
        for index in entries.indices { entries[index].included = false }
    }

    /// The technician went through the step and this is their answer.
    func confirmed() -> EvidenceSelection {
        EvidenceSelection(reviewed: true, entries: entries)
    }

    /// "Skip photos". The record goes out exactly as it did before any of this existed — which is
    /// why this clears `reviewed` rather than confirming an empty selection.
    static func skipped() -> EvidenceSelection {
        EvidenceSelection(reviewed: false, entries: [])
    }
}
