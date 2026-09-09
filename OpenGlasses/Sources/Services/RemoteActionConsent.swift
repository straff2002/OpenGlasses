import Foundation

/// Who is asking for a remote/agentic action (Plan BN P1) — every consent prompt carries its
/// origin, the same narration principle as BK P2c. Shared by Plan N (coding-agent confirms),
/// Plan BH (gateway remote invoke), and Plan BL (an MCP ops peer driving the glasses).
enum RemoteActionSource: Equatable {
    case assistant              // the local assistant's own high-impact tool call
    case codingAgent            // Plan N remote agent run
    case gateway                // Plan BH gateway remote invoke
    case opsPeer(label: String) // Plan BL MCP peer

    /// The subject of the consent sentence: "The coding agent wants: …".
    var line: String {
        switch self {
        case .assistant:          return "The assistant"
        case .codingAgent:        return "The coding agent"
        case .gateway:            return "The gateway"
        case .opsPeer(let label): return label.isEmpty ? "An ops platform" : label
        }
    }
}

/// One consent ask: the source plus what it wants. Pure prompt composition so the HUD card and
/// the spoken prompt always carry the attribution.
struct RemoteActionConsentRequest: Equatable {
    let source: RemoteActionSource
    let summary: String

    /// Source-attributed line for the card + audit: "The gateway wants: take a photo".
    var attributedSummary: String { "\(source.line) wants: \(summary)" }

    /// The spoken form.
    var spokenPrompt: String { "\(attributedSummary). Approve?" }
}

/// The versioned, withdrawable half of the shared consent surface (W04.3).
///
/// A confirmation prompt answers one call. What it cannot do on its own is remember: which terms
/// the wearer agreed to, that those terms have since changed, or that the wearer has told this
/// source to stop. This gate is the pure policy that turns the register of [[ConsentRecord]]s into
/// those three answers, and it sits under the existing prompt rather than beside it — the wearer
/// sees the same card, and what changes is whether it is shown at all and what it says.
enum RemoteActionConsentGate {

    /// The purpose, data class, recipient and terms version one source's consent is recorded
    /// against.
    struct Terms: Equatable {
        let purpose: ConsentPurpose
        let dataClass: ConsentDataClass
        /// Stable, source-derived, and never a person's name.
        let recipient: String
        let version: Int
    }

    struct Decision: Equatable {
        let outcome: ConsentOutcome
        /// False only when the wearer has withdrawn: asking again straight after somebody says
        /// stop is how a consent surface turns into a nuisance dialog.
        let allowsPrompt: Bool
        /// An extra line in front of the ask, when the wearer is being asked under terms they have
        /// not agreed to at this version.
        let promptPrefix: String?
        /// Whether approving should write a fresh record.
        let shouldRecordOnApproval: Bool

        /// What a coordinator with no register behind it does: ask, and remember nothing.
        static let noLedger = Decision(outcome: .notGranted, allowsPrompt: true,
                                       promptPrefix: nil, shouldRecordOnApproval: false)
    }

    /// The terms in force for a source. The recipient is the source's own identity, so withdrawing
    /// consent for the gateway does not silently withdraw it for an ops peer.
    static func terms(for source: RemoteActionSource) -> Terms {
        Terms(purpose: .remoteAction, dataClass: .none, recipient: recipient(for: source),
              version: ConsentPurpose.remoteAction.currentVersion)
    }

    /// A stable, content-free identity for a source. An ops peer's label is wearer-authored text,
    /// so it is reduced to a fingerprint rather than stored verbatim.
    static func recipient(for source: RemoteActionSource) -> String {
        switch source {
        case .assistant:          return "assistant"
        case .codingAgent:        return "coding-agent"
        case .gateway:            return "gateway"
        case .opsPeer(let label): return "ops-peer:" + ToolAuthorizationEventLog.fingerprint(label)
        }
    }

    static func decide(source: RemoteActionSource, records: [ConsentRecord],
                       at now: Date = Date()) -> Decision {
        let terms = terms(for: source)
        let outcome = ConsentPolicy.evaluate(
            purpose: terms.purpose, dataClass: terms.dataClass, recipient: terms.recipient,
            requiredVersion: terms.version, actor: .wearer, in: records, at: now)

        switch outcome {
        case .granted:
            return Decision(outcome: outcome, allowsPrompt: true, promptPrefix: nil,
                            shouldRecordOnApproval: false)
        case .withdrawn:
            return Decision(outcome: outcome, allowsPrompt: false, promptPrefix: nil,
                            shouldRecordOnApproval: false)
        case .notGranted:
            return Decision(outcome: outcome, allowsPrompt: true, promptPrefix: nil,
                            shouldRecordOnApproval: true)
        case .stale:
            return Decision(outcome: outcome, allowsPrompt: true,
                            promptPrefix: "What you agreed to has changed.",
                            shouldRecordOnApproval: true)
        }
    }

    /// What the model is told when the wearer has withdrawn consent for this source. Says the
    /// wearer's decision stands, and gives the model nothing to argue with.
    static func withdrawnMessage(tool: String) -> String {
        "The user has withdrawn permission for this kind of action, so '\(tool)' did not run and "
            + "nothing was asked. Do not retry; tell the user it is turned off in settings."
    }
}

/// PURE voice yes/no interpretation for a pending consent prompt (the voice half of the shared
/// surface). Deliberately conservative: only short, unambiguous utterances count — anything else
/// returns `nil` and flows to the normal turn pipeline. Never guess an approval.
enum RemoteActionVoiceConsent {

    /// `true` = approve, `false` = deny, `nil` = not a consent answer.
    static func interpret(_ text: String) -> Bool? {
        let normalized = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
        guard !normalized.isEmpty, normalized.split(separator: " ").count <= 3 else { return nil }
        if matches(normalized, any: approvals) { return true }
        if matches(normalized, any: denials) { return false }
        return nil
    }

    private static let approvals: Set<String> = [
        "yes", "yep", "yeah", "approve", "approved", "confirm", "confirmed",
        "go ahead", "do it", "proceed", "ok", "okay",
    ]
    private static let denials: Set<String> = [
        "no", "nope", "deny", "denied", "cancel", "stop", "decline", "abort", "don't",
    ]
    /// Trailing words that don't change the answer ("yes please", "cancel it").
    private static let politeness: Set<String> = ["please", "thanks", "sure", "it", "that"]

    private static func matches(_ text: String, any phrases: Set<String>) -> Bool {
        if phrases.contains(text) { return true }
        for phrase in phrases where text.hasPrefix(phrase + " ") {
            let rest = text.dropFirst(phrase.count + 1).split(separator: " ").map(String.init)
            if !rest.isEmpty, rest.allSatisfy({ politeness.contains($0) }) { return true }
        }
        return false
    }
}
