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

/// What a request for a *bound* approval came back with.
///
/// `approved` carries a single-use nonce rather than a bare `true`: a yes that is only a boolean
/// can be spent by any call that happens to be next, which is the hole this closes.
enum ApprovalDecision: Equatable {
    case approved(nonce: String)
    case denied
    /// The wearer has withdrawn consent for this source, so nothing was asked.
    case consentWithdrawn
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

    /// Issues the single-use grants that bind an approval to the exact call it was given for.
    /// Owned here because this is where a person actually says yes; the dispatch point spends
    /// them.
    let approvalGrants: ApprovalGrantStore

    /// The versioned consent register behind the shared surface. Optional so a headless or
    /// test-built coordinator keeps the plain confirm-only behaviour; when set, a source whose
    /// consent has been withdrawn is refused without asking, and a terms version bump changes what
    /// the wearer is asked.
    var consentStore: ConsentStore?

    /// `approvalGrants` is optional rather than defaulted to a fresh store because a default
    /// argument is evaluated at the call site, which is not always on the main actor.
    init(approvalGrants: ApprovalGrantStore? = nil, consentStore: ConsentStore? = nil) {
        self.approvalGrants = approvalGrants ?? ApprovalGrantStore()
        self.consentStore = consentStore
    }

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

    /// Ask for an approval that is *bound* to one call, and hand back a single-use nonce for it.
    ///
    /// This is the same prompt, the same card and the same spoken line as
    /// ``requestConfirmation(toolName:summary:source:)`` — only what a yes is worth has changed.
    /// Before asking, the versioned consent register is consulted: a source the wearer has
    /// withdrawn consent for is refused without a prompt, and terms the wearer has not agreed to at
    /// the current version are named in the ask and recorded when they agree.
    func requestApproval(toolName: String, summary: String,
                         source: RemoteActionSource = .assistant,
                         binding: ApprovalBinding,
                         at now: Date = Date(),
                         ttl: TimeInterval = ApprovalGrant.defaultTTL) async -> ApprovalDecision {
        let consent = consentDecision(for: source, at: now)
        guard consent.allowsPrompt else {
            PrivacyLog.toolGate(.consentWithdrawn, tool: toolName)
            return .consentWithdrawn
        }
        let asked = consent.promptPrefix.map { "\($0) \(summary)" } ?? summary
        let approved = await requestConfirmation(toolName: toolName, summary: asked, source: source)
        guard approved else { return .denied }
        record(consent, for: source, at: now)
        return .approved(nonce: approvalGrants.issue(for: binding, at: now, ttl: ttl).nonce)
    }

    private func consentDecision(for source: RemoteActionSource,
                                 at now: Date) -> RemoteActionConsentGate.Decision {
        guard let consentStore else { return .noLedger }
        return RemoteActionConsentGate.decide(source: source, records: consentStore.records, at: now)
    }

    private func record(_ decision: RemoteActionConsentGate.Decision,
                        for source: RemoteActionSource, at now: Date) {
        guard let consentStore, decision.shouldRecordOnApproval else { return }
        let terms = RemoteActionConsentGate.terms(for: source)
        consentStore.recordWearerApproval(purpose: terms.purpose, dataClass: terms.dataClass,
                                          recipient: terms.recipient, version: terms.version,
                                          at: now)
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
