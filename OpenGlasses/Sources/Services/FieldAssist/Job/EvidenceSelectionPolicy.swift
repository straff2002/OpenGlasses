import Foundation

/// Which evidence selection the report actually uses (Plan GB P3).
///
/// Job 1011's technician untucked a blurry photo on the Job tab and the report still carried it:
/// the tick on the thumbnail changed nothing, and even a stored choice was honoured only once the
/// close review had happened — which a voice close skips. A choice the technician made is a
/// choice, whichever screen they made it on. So a selection counts when it was reviewed **or**
/// when any entry in it was explicitly decided; an entry nobody decided keeps its default. A job
/// nobody chose anything for still sends the text-only record it always has.
enum EvidenceSelectionPolicy {

    /// The selection to render and send, or nil when nothing was chosen.
    static func effective(_ selection: EvidenceSelection?) -> EvidenceSelection? {
        guard let selection else { return nil }
        if selection.reviewed { return selection }
        guard isDecided(selection) else { return nil }
        return EvidenceSelection(reviewed: true, entries: selection.entries)
    }

    /// Whether the technician has said anything about the evidence yet.
    static func isDecided(_ selection: EvidenceSelection?) -> Bool {
        guard let selection else { return false }
        return selection.reviewed || selection.entries.contains { $0.decided == true }
    }
}

extension EvidenceSelection {
    /// Include or leave out one item, as the technician's explicit choice (Plan GB P3).
    mutating func decide(_ itemId: String, included: Bool) {
        guard let index = entries.firstIndex(where: { $0.itemId == itemId }) else { return }
        entries[index].included = included
        entries[index].decided = true
    }

    /// Mark every item decided as it stands: "send them as they are".
    mutating func decideAll(included: Bool? = nil) {
        for index in entries.indices {
            if let included { entries[index].included = included }
            entries[index].decided = true
        }
    }
}
