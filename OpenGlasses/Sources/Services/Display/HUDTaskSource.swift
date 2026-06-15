import Foundation
import Combine

/// One step of a workflow/SOP as the HUD needs it — source-agnostic so the Now/Next
/// card doesn't care whether it's a linear Playbook or a branching Field Assist
/// Procedure.
struct HUDStep: Equatable {
    let index: Int           // 0-based
    let total: Int?          // nil for branching procedures with no fixed length
    let title: String
    let instruction: String?
    let safetyNote: String?
    let icon: GlassesDisplayService.HUDIcon

    init(index: Int,
         total: Int?,
         title: String,
         instruction: String? = nil,
         safetyNote: String? = nil,
         icon: GlassesDisplayService.HUDIcon = .none) {
        self.index = index
        self.total = total
        self.title = title
        self.instruction = instruction
        self.safetyNote = safetyNote
        self.icon = icon
    }
}

/// A branch choice at a decision step (Field Assist procedures). Linear sources
/// (Playbooks) expose none.
struct HUDChoice: Equatable, Identifiable {
    let id: String
    let label: String
}

/// Adapter a step-based engine implements so `HUDRouter` can render and drive it from
/// the Neural Band. Conformers: `PlaybookHUDTaskSource` (linear) and
/// `ProcedureHUDTaskSource` (branching Field Assist SOPs).
@MainActor
protocol HUDTaskSource: AnyObject {
    /// Workflow / procedure name (rendered as the card heading).
    var title: String { get }
    /// The NOW step, or nil when the workflow has finished.
    var current: HUDStep? { get }
    /// The NEXT step (preview), or nil when on the last/branching step.
    var next: HUDStep? { get }
    /// Branch options at a decision step. Empty ⇒ a linear Done/Skip/Back card;
    /// non-empty ⇒ the card renders one button per choice (+ Back).
    var choices: [HUDChoice] { get }
    /// Emits whenever `current`/`next`/`choices` may have changed, so the card re-renders.
    var changes: AnyPublisher<Void, Never> { get }

    func complete() async        // mark current done → advance
    func skip() async            // skip current → advance
    func back() async            // previous step
    func choose(_ id: String) async   // take a specific branch
}

extension HUDTaskSource {
    var choices: [HUDChoice] { [] }
    func choose(_ id: String) async {}
}
