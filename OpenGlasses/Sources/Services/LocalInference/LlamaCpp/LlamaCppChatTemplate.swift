import Foundation

/// The embedded chat template, validated once at load and then applied to every turn.
///
/// Plan DZ invariant 5: "The model's embedded chat template is authoritative." Two consequences
/// live here. First, a model whose template cannot render a minimal system/user/assistant exchange
/// is refused at load rather than discovered to be broken mid-conversation. Second, a template that
/// silently *drops* the system role — Gemma's does, folding it into the first user turn — is
/// detected by probe rather than by architecture name, and the system text is merged into the first
/// user turn so it is never lost.
///
/// Everything except `validate`'s single injected `apply` closure is pure.

/// Why a template cannot be used for chat.
enum LlamaChatTemplateFault: Error, Equatable, Sendable {
    /// The GGUF carries no template at all.
    case absent
    /// The engine refused to render the probe exchange.
    case renderFailed
    /// It rendered, but to nothing.
    case emptyRender
    /// The user turn's text did not survive rendering.
    case dropsUserContent
    /// The assistant turn's text did not survive rendering.
    case dropsAssistantContent
    /// Asking for the assistant header produced the same text as not asking, so there is no way to
    /// tell the model it is its turn to speak.
    case noAssistantHeader
}

/// What the probe learned about a usable template.
struct LlamaChatTemplateProfile: Equatable, Sendable {
    let template: String
    /// Whether a `system` turn's text survives rendering. When false the caller must merge system
    /// text into the first user turn or the model never sees it.
    let rendersSystemRole: Bool

    var mergesSystemIntoFirstUser: Bool { !rendersSystemRole }
}

enum LlamaCppChatTemplate {

    // Probe strings. Deliberately unlike anything a template emits of its own accord, so a
    // `contains` check cannot be satisfied by the template's own boilerplate. Never user-visible.
    private static let systemProbe = "OGPROBE-SYSTEM-4C1F"
    private static let userProbe = "OGPROBE-USER-4C1F"
    private static let assistantProbe = "OGPROBE-ASSISTANT-4C1F"

    /// Render a minimal system/user/assistant exchange and check the template can carry a
    /// conversation (Plan DZ load step 4).
    ///
    /// `apply` is the engine's template renderer: `(template, turns, addAssistantHeader)`.
    static func validate(
        _ template: String?,
        apply: (String, [LlamaChatTurn], Bool) throws -> String
    ) -> Result<LlamaChatTemplateProfile, LlamaChatTemplateFault> {
        guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.absent)
        }
        let probe = [
            LlamaChatTurn(role: "system", content: systemProbe),
            LlamaChatTurn(role: "user", content: userProbe),
            LlamaChatTurn(role: "assistant", content: assistantProbe),
        ]

        let rendered: String
        let withHeader: String
        do {
            rendered = try apply(template, probe, false)
            withHeader = try apply(template, probe, true)
        } catch {
            return .failure(.renderFailed)
        }

        guard !rendered.isEmpty else { return .failure(.emptyRender) }
        guard rendered.contains(userProbe) else { return .failure(.dropsUserContent) }
        guard rendered.contains(assistantProbe) else { return .failure(.dropsAssistantContent) }
        guard withHeader.count > rendered.count else { return .failure(.noAssistantHeader) }

        return .success(LlamaChatTemplateProfile(template: template,
                                                 rendersSystemRole: rendered.contains(systemProbe)))
    }

    /// Turn the seam's messages into template turns, applying the two policies the template's own
    /// shape decides.
    ///
    /// **System hoisting.** Every template in circulation accepts at most one leading system turn;
    /// a system instruction appearing mid-conversation is not portable. Rather than drop it or hand
    /// it to a template that would refuse it, all system messages are joined in order into one
    /// leading turn. The user/assistant turns keep their order untouched.
    ///
    /// **System merging.** When the template does not render the system role, the system text is
    /// prefixed to the first user turn. No `User:`/`Assistant:` labels are added: the template owns
    /// the turn markers, and inventing text labels inside a turn is how a model starts answering as
    /// the wrong speaker.
    static func turns(from messages: [LocalChatMessage],
                      mergingSystemIntoFirstUser: Bool) -> [LlamaChatTurn] {
        var systemParts: [String] = []
        var conversation: [LlamaChatTurn] = []

        for message in messages {
            switch message.role {
            case .system:
                let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { systemParts.append(message.content) }
            case .user:
                conversation.append(LlamaChatTurn(role: "user", content: message.content))
            case .assistant:
                conversation.append(LlamaChatTurn(role: "assistant", content: message.content))
            }
        }

        let systemText = systemParts.joined(separator: "\n\n")
        guard !systemText.isEmpty else { return conversation }

        if !mergingSystemIntoFirstUser {
            return [LlamaChatTurn(role: "system", content: systemText)] + conversation
        }
        guard let firstUser = conversation.firstIndex(where: { $0.role == "user" }) else {
            // No user turn to merge into. A lone system instruction becomes the user turn rather
            // than being dropped — the alternative is a prompt the model never sees.
            return [LlamaChatTurn(role: "user", content: systemText)] + conversation
        }
        conversation[firstUser] = LlamaChatTurn(
            role: "user",
            content: systemText + "\n\n" + conversation[firstUser].content)
        return conversation
    }

    /// Whether the tokenizer should add its own special tokens to an already-rendered template.
    ///
    /// Templates differ: some emit the BOS token as text, some leave it to the tokenizer. Adding it
    /// on top of a template that already wrote one gives the model two, which every model reads as
    /// a malformed prompt. The rendered text is the evidence — not the architecture, not the name.
    static func shouldAddSpecialTokens(rendered: String,
                                       bosPiece: String?,
                                       vocabularyAddsBOS: Bool) -> Bool {
        guard vocabularyAddsBOS else { return false }
        guard let bosPiece, !bosPiece.isEmpty else { return true }
        return !rendered.hasPrefix(bosPiece)
    }
}
