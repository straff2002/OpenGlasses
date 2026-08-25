import Foundation
import Combine

/// A high-impact tool action waiting for the user to approve or deny it.
struct PendingToolConfirmation: Identifiable {
    let id = UUID()
    let toolName: String
    /// Human-readable description of what will happen (e.g. "Send a message to Mom: …").
    let summary: String
    /// Who is asking (BN P1) — drives the source line on the consent card + spoken prompt.
    let source: RemoteActionSource
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
    /// prompts (the model can retry after the user has dealt with the first one). `source`
    /// attributes the ask on the card and in the spoken prompt (BN P1).
    func requestConfirmation(toolName: String, summary: String, source: RemoteActionSource = .assistant) async -> Bool {
        if pending != nil { return false }
        // Plan DE: being asked before the assistant acts is the moment a user learns it
        // *acts* — the tool surface is where they decide what it may act on. Suggestion
        // only, raised at most once ever, and never affecting this confirmation.
        SettingsJourneyStore.note(.highImpactActionConfirmed)
        onSpeakPrompt?(RemoteActionConsentRequest(source: source, summary: summary).spokenPrompt)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pending = PendingToolConfirmation(toolName: toolName, summary: summary, source: source, continuation: continuation)
        }
    }

    /// Resolve the outstanding confirmation. Called by the UI when the user taps Approve / Deny.
    func resolve(_ approved: Bool) {
        guard let p = pending else { return }
        pending = nil
        p.continuation.resume(returning: approved)
    }

    /// Voice half of the shared consent surface (BN P1): interpret a wearer utterance as an
    /// answer to the pending prompt. Returns `true` when the utterance was consumed (the prompt
    /// resolved); `false` leaves the prompt pending and the utterance for the normal turn
    /// pipeline. Never resolves on an ambiguous phrase.
    @discardableResult
    func resolveByVoice(_ text: String) -> Bool {
        guard pending != nil, let approved = RemoteActionVoiceConsent.interpret(text) else { return false }
        resolve(approved)
        return true
    }
}
