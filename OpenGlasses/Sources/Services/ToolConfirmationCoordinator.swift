import Foundation
import Combine

/// A high-impact tool action waiting for the user to approve or deny it.
struct PendingToolConfirmation: Identifiable {
    let id = UUID()
    let toolName: String
    /// Human-readable description of what will happen (e.g. "Send a message to Mom: …").
    let summary: String
    fileprivate let continuation: CheckedContinuation<Bool, Never>
}

/// Human-in-the-loop gate for destructive / high-impact tool calls.
///
/// When agent mode is on, ``NativeToolRouter`` routes high-impact actions (see
/// ``PromptInjectionPolicy/highImpactTools``) through here before executing them: this publishes a
/// `pending` request, the UI presents an Approve / Deny prompt, and the router's call suspends
/// until the user decides. This is the prompt-injection backstop — even if injected text in a tool
/// result convinces the model to call a destructive tool, nothing actually happens without an
/// explicit human approval.
@MainActor
final class ToolConfirmationCoordinator: ObservableObject {
    /// The action currently awaiting a decision, or nil. Observed by the UI to present a prompt.
    @Published var pending: PendingToolConfirmation?

    /// Optional hook to speak the confirmation prompt aloud (wired to TTS by AppState), so the
    /// user can hear what they're being asked to approve when wearing the glasses.
    var onSpeakPrompt: ((String) -> Void)?

    /// Suspend until the user approves or denies `toolName`. Returns `true` to proceed.
    /// If another confirmation is already outstanding, the new request is denied to avoid stacking
    /// prompts (the model can retry after the user has dealt with the first one).
    func requestConfirmation(toolName: String, summary: String) async -> Bool {
        if pending != nil { return false }
        onSpeakPrompt?("Confirm: \(summary)?")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pending = PendingToolConfirmation(toolName: toolName, summary: summary, continuation: continuation)
        }
    }

    /// Resolve the outstanding confirmation. Called by the UI when the user taps Approve / Deny.
    func resolve(_ approved: Bool) {
        guard let p = pending else { return }
        pending = nil
        p.continuation.resume(returning: approved)
    }
}
