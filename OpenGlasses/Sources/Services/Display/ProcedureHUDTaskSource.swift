import Foundation
import Combine

/// The slice of `FieldSessionService` the HUD procedure source needs. Abstracted to a
/// protocol so the adapter is unit-testable without standing up a full vault + session.
@MainActor
protocol ProcedureHosting: AnyObject {
    var activeProcedureStep: Procedure.Step? { get }
    var activeProcedureTitle: String? { get }
    var objectWillChange: ObservableObjectPublisher { get }
    @discardableResult func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition
    @discardableResult func procedureBack() throws -> Procedure.Step
}

extension FieldSessionService: ProcedureHosting {}

/// Adapts a running Field Assist **Procedure** (branching SOP) to the HUD's
/// `HUDTaskSource`, so it renders as a Now/Next card with per-branch choice buttons.
/// Pure glue — the step graph and audit logging stay in `ProcedureRunner`.
@MainActor
final class ProcedureHUDTaskSource: HUDTaskSource {
    private let host: ProcedureHosting

    init(host: ProcedureHosting = FieldSessionService.shared) {
        self.host = host
    }

    var changes: AnyPublisher<Void, Never> {
        host.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    private var step: Procedure.Step? { host.activeProcedureStep }

    var title: String { host.activeProcedureTitle ?? "Procedure" }

    var current: HUDStep? {
        guard let step else { return nil }
        let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return HUDStep(
            index: 0,
            total: nil,                              // branching graph — no fixed length
            title: step.title,
            instruction: instruction.isEmpty ? nil : instruction,
            safetyNote: step.safetyNote,
            icon: step.terminal ? .success : .navigation
        )
    }

    /// Branching procedures have no single linear "next" to preview.
    var next: HUDStep? { nil }

    var choices: [HUDChoice] {
        (step?.branches ?? []).map { HUDChoice(id: $0.id, label: $0.condition) }
    }

    func complete() async { _ = try? host.advanceProcedure(choice: nil) }   // follow default_next / finish terminal
    func skip() async { _ = try? host.advanceProcedure(choice: nil) }       // procedures don't skip — treat as advance
    func back() async { _ = try? host.procedureBack() }
    func choose(_ id: String) async { _ = try? host.advanceProcedure(choice: id) }
}
