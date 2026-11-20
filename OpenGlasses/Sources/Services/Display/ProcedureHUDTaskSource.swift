import Foundation
import Combine

/// The slice of `FieldSessionService` the HUD procedure source needs. Abstracted to a
/// protocol so the adapter is unit-testable without standing up a full vault + session.
/// Answers and the run's state come through `ProcedureAnswering` (Plan MN §4).
@MainActor
protocol ProcedureHosting: ProcedureAnswering {
    var activeProcedureStep: Procedure.Step? { get }
    var activeProcedureTitle: String? { get }
    var objectWillChange: ObservableObjectPublisher { get }
}

extension FieldSessionService: ProcedureHosting {}

/// Adapts a running Field Assist **Procedure** (branching SOP) to the HUD's
/// `HUDTaskSource`, so it renders as a Now/Next card with per-branch choice buttons.
/// Pure glue — the step graph and audit logging stay in `ProcedureRunner`.
///
/// Plan MN §4: a `choice` or `yes_no` step waiting for its answer shows the answer's options as
/// buttons, a spoken critical answer shows its read-back's yes and no, and once a number (or any
/// answer) is recorded the card says what was recorded. A number is spoken or typed on the phone.
@MainActor
final class ProcedureHUDTaskSource: HUDTaskSource {
    private let host: ProcedureHosting

    // Default resolved in the body (not the signature): `FieldSessionService.shared` is
    // main-actor-isolated, and a default argument is evaluated in the caller's (possibly
    // nonisolated) context, which Swift 6 rejects.
    init(host: ProcedureHosting? = nil) {
        self.host = host ?? FieldSessionService.shared
    }

    var changes: AnyPublisher<Void, Never> {
        host.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    private var step: Procedure.Step? { host.activeProcedureStep }
    private var presentation: ProcedureStepPresentation? { host.activeProcedurePresentation }

    var title: String { host.activeProcedureTitle ?? String(localized: "Procedure") }

    var current: HUDStep? {
        guard let step else { return nil }
        let instruction: String?
        if let presentation, presentation.step.id == step.id {
            instruction = presentation.lensInstruction
        } else {
            let trimmed = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            instruction = trimmed.isEmpty ? nil : trimmed
        }
        return HUDStep(
            index: 0,
            total: nil,                              // branching graph — no fixed length
            title: step.title,
            instruction: instruction,
            safetyNote: step.safetyNote,
            icon: step.terminal ? .success : .navigation,
            video: HUDVideo.playable(step.videoURL)
        )
    }

    /// Branching procedures have no single linear "next" to preview.
    var next: HUDStep? { nil }

    var choices: [HUDChoice] {
        if let presentation, presentation.step.id == step?.id { return presentation.lensChoices }
        return (step?.branches ?? []).map { HUDChoice(id: $0.id, label: $0.condition) }
    }

    // Done follows the rules or `default_next` and finishes a terminal step; on a photo step it
    // attaches the photos taken on the step first.
    func complete() async { _ = try? host.advanceProcedureAttachingPhotos() }
    func skip() async { _ = try? host.advanceProcedureAttachingPhotos() }       // procedures don't skip — treat as advance
    func back() async { _ = try? host.procedureBack() }

    func choose(_ id: String) async {
        switch id {
        case ProcedureStepPresentation.readBackYesId:
            _ = try? host.confirmProcedureReadBack(true)
        case ProcedureStepPresentation.readBackNoId:
            _ = try? host.confirmProcedureReadBack(false)
        case let answer where answer.hasPrefix(ProcedureStepPresentation.answerButtonPrefix):
            let value = String(answer.dropFirst(ProcedureStepPresentation.answerButtonPrefix.count))
            _ = try? host.answerProcedure(value: value, method: .lens, note: nil, confirmed: false, locale: .current)
        default:
            _ = try? host.advanceProcedure(choice: id)
        }
    }
}
