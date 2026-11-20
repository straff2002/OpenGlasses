import SwiftUI
import UIKit

/// Plan MN P3 — the procedure review screen's state: the procedure being edited, the suggestions
/// from a reply pasted from the author's own AI, and the save. A thin shell over the pure
/// `ProcedureRuleReview`; nothing is written to the vault until *Save*.
@MainActor
final class ProcedureRulesModel: ObservableObject {
    @Published private(set) var review: ProcedureRuleReview?
    @Published var pasteText = ""
    @Published private(set) var promptCopied = false
    @Published private(set) var replyRead = false
    @Published var message: String?
    @Published var errorMessage: String?
    private(set) var vaultId = ""
    private(set) var file = ""

    func load(vaultId: String, file: String, fixture: Procedure? = nil) {
        self.vaultId = vaultId
        self.file = file
        let procedure = fixture ?? ProcedureAuthoring.entries(vaultId: vaultId).first { $0.file == file }?.procedure
        review = procedure.map(ProcedureRuleReview.init)
    }

    // MARK: - The kit

    func copyPrompt() {
        guard let review else { return }
        UIPasteboard.general.string = review.prompt
        promptCopied = true
    }

    func checkReply() {
        review?.readReply(pasteText)
        replyRead = true
    }

    func accept(_ id: String) { review?.accept(id); message = nil }
    func reject(_ id: String) { review?.reject(id) }

    // MARK: - Edits

    func setAnswer(_ answer: StepAnswer?, onStep stepId: String) {
        review?.setAnswer(answer, onStep: stepId)
        message = nil
    }

    func setRule(_ rule: BranchRule?, branch: String, step: String) {
        review?.setRule(rule, branch: branch, step: step)
        message = nil
    }

    func removeRules(onStep stepId: String) {
        review?.removeRules(onStep: stepId)
        message = nil
    }

    func save() {
        guard let review else { return }
        errorMessage = nil
        do {
            try ProcedureAuthoring.save(review.editing, file: file, vaultId: vaultId)
            self.review?.saved()
            message = String(localized: "Saved. The next run of this procedure uses it.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
