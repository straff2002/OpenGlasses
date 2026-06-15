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

/// Adapter a step-based engine implements so `HUDRouter` can render and drive it from
/// the Neural Band. Conformers: `PlaybookHUDTaskSource` (Plan X) and, later, a
/// Field Assist `ProcedureRunner` adapter.
@MainActor
protocol HUDTaskSource: AnyObject {
    /// Workflow / procedure name (rendered as the card heading).
    var title: String { get }
    /// The NOW step, or nil when the workflow has finished.
    var current: HUDStep? { get }
    /// The NEXT step (preview), or nil when on the last step.
    var next: HUDStep? { get }
    /// Emits whenever `current`/`next` may have changed, so the card re-renders.
    var changes: AnyPublisher<Void, Never> { get }

    func complete() async   // mark current done → advance
    func skip() async       // skip current → advance
    func back() async       // previous step
}
