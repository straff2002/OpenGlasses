import Foundation
import Combine

/// Adapts the linear [PlaybookStore](PlaybookStore.swift) workflow engine to the HUD's
/// `HUDTaskSource`, so a running Playbook renders as a Now/Next card the Neural Band
/// can drive. Pure glue — all step logic stays in `PlaybookStore`.
@MainActor
final class PlaybookHUDTaskSource: HUDTaskSource {
    private let store: PlaybookStore

    init(store: PlaybookStore) {
        self.store = store
    }

    /// `PlaybookStore` is an `ObservableObject`; its `objectWillChange` fires on every
    /// session mutation. `HUDRouter` defers the actual read to the next main-actor tick,
    /// by which point `activeSession` reflects the new step.
    var changes: AnyPublisher<Void, Never> {
        store.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    private var session: PlaybookSession? { store.activeSession }
    private var playbook: Playbook? { session.flatMap { store.playbook(byId: $0.playbookId) } }

    var title: String { playbook?.name ?? "Workflow" }

    var current: HUDStep? { step(at: session?.currentStepIndex, instruction: true) }

    var next: HUDStep? { step(at: session.map { $0.currentStepIndex + 1 }, instruction: false) }

    private func step(at index: Int?, instruction: Bool) -> HUDStep? {
        guard let index, let pb = playbook, index >= 0, index < pb.steps.count else { return nil }
        let step = pb.steps[index]
        let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return HUDStep(
            index: index,
            total: pb.steps.count,
            title: step.title,
            instruction: (instruction && !detail.isEmpty) ? detail : nil,
            safetyNote: nil,          // Playbooks have no safety notes (that's Field Assist)
            icon: .none
        )
    }

    func complete() async { _ = store.nextStep() }            // marks current complete + advances
    func skip() async { _ = store.skipCurrentStep(reason: "Skipped from HUD") }
    func back() async { _ = store.previousStep() }
}
