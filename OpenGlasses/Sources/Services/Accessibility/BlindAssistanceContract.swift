import Foundation

/// The one instruction block every path that speaks for a blind or low-vision wearer composes.
///
/// Before this existed, each surface carried its own idea of what assisting a blind user meant.
/// The live preset asked for *detail* and named no uncertainty rule at all; the navigation loop
/// graded its own lowest urgency as "clear path", which is the single sentence an assistive aid
/// must never say; the narration, assistive-mode and reading prompts each hedged differently or
/// not at all. A wearer who cannot check the answer against the room was getting a different
/// safety posture depending on which code path happened to answer.
///
/// So the rules live here once, as ``Fragment`` values, and every surface composes the subset that
/// applies to it. Composition — not copy-paste — is the point: ``applying(_:to:)`` skips a fragment
/// whose text the base prompt already carries, so a path that inherits the full contract from the
/// live preset and then adds its own fragments does not say the same thing twice.
///
/// Scope note: this is prompt content. It shapes what a model is asked to do; it does not and
/// cannot guarantee what a model says. `BlindAssistanceResponseAudit` is the other half — it
/// classifies what actually came back — and neither amounts to a safety certification.
enum BlindAssistanceContract {

    /// The `LiveAIMode` id whose prompt prefix *is* this contract.
    static let presetID = "accessibility"

    // MARK: - Fragments

    /// One rule of the contract. `allCases` order is the canonical order every composition uses,
    /// so two paths carrying overlapping subsets read the same way.
    enum Fragment: String, CaseIterable {
        /// One useful observation, hazards first; detail on request.
        case brevity
        /// Clock position and distance only when the image supports it.
        case spatialCertainty
        /// Faithful reading; transcription vs partial vs interpretation; never fill in a gap.
        case faithfulReading
        /// No assurance that moving is safe, or that an unseen hazard is absent.
        case noSafetyAssurance
        /// The wearer's cane, dog and judgement lead; this is a supplement.
        case mobilityAids
        /// No phrasing that assumes the wearer can see.
        case noVisualAssumptions
        /// The surrounding task's output format survives these rules unchanged.
        case preserveFormat

        var text: String {
            switch self {
            case .brevity:
                return """
                Give one short, useful observation by default, leading with any hazard you \
                actually observe; add more detail only when the user asks for it.
                """
            case .spatialCertainty:
                return """
                State a clock position or an approximate distance only when the image itself \
                supports it; otherwise say that the position or distance is uncertain.
                """
            case .faithfulReading:
                return """
                Read requested text faithfully and say which you are giving: an exact \
                transcription, only part of the text, or your interpretation. Never fill in a \
                medication name, quantity, date or instruction you cannot actually read — \
                unreadable stays unreadable.
                """
            case .noSafetyAssurance:
                return """
                Never say or imply that moving, crossing or proceeding is safe, and never state \
                that a hazard is absent. You can only report what is visible in this view, not \
                what is not there.
                """
            case .mobilityAids:
                return """
                Say what your visual evidence does not cover. The user's cane, guide dog and own \
                judgement lead; you supplement them and never replace them.
                """
            case .noVisualAssumptions:
                return """
                Never use phrasing that assumes the user can see, such as "as you can see", \
                "look at" or "you'll notice".
                """
            case .preserveFormat:
                return """
                Keep the exact output format this task specifies. These rules change the wording \
                inside that format, never the format itself.
                """
            }
        }
    }

    /// Fragments for a path that describes the environment the wearer is moving through.
    static let environmentFragments: [Fragment] =
        [.spatialCertainty, .noSafetyAssurance, .mobilityAids, .noVisualAssumptions, .preserveFormat]

    /// Fragments for a path that reads text back to the wearer.
    static let readingFragments: [Fragment] =
        [.faithfulReading, .noVisualAssumptions, .preserveFormat]

    /// Fragments for a path that does neither — it still speaks to someone who cannot see.
    static let spokenOutputFragments: [Fragment] = [.noVisualAssumptions, .preserveFormat]

    // MARK: - Composition

    /// The heading every composed block is filed under, so the rules are findable in a long prompt
    /// and so `applying(_:to:)` can tell an already-composed prompt from a bare one.
    static let heading = "BLIND ASSISTANCE:"

    /// The full contract, all fragments, in canonical order. This is what the live preset carries.
    static var instruction: String { block(Fragment.allCases) }

    /// The `LiveAIMode.promptPrefix` for the Blind Assistant preset.
    ///
    /// Trailing blank line because the realtime builders concatenate the prefix straight onto the
    /// configured system prompt, exactly as every other preset does.
    static var presetPrefix: String { instruction + "\n\n" }

    /// Render fragments as a headed block. Fragments are emitted in `allCases` order regardless of
    /// the order they were requested in, which is what makes two paths' overlapping subsets read
    /// identically rather than merely contain the same sentences.
    static func block(_ fragments: [Fragment]) -> String {
        let ordered = Fragment.allCases.filter(Set(fragments).contains)
        let lines = ordered.map { "- " + flatten($0.text) }
        return ([heading, lede] + lines).joined(separator: "\n")
    }

    /// The sentence that explains who the rules are for. Without it the bullets read as style
    /// preferences rather than as the reason the wearer cannot double-check the answer.
    static let lede = """
        You are assisting a user who is blind or has low vision and cannot check what you say \
        against what is in front of them.
        """

    /// Append the fragments a prompt does not already carry.
    ///
    /// The already-carries check is per fragment rather than per block, because the paths overlap
    /// unevenly: a live session under the Blind Assistant preset already holds all seven, while a
    /// reading tool result composed inside that same session holds none of them until this runs.
    /// Returns `base` untouched when every requested fragment is already present — no stray
    /// heading, so a prompt that composes twice is byte-identical to one that composes once.
    static func applying(_ fragments: [Fragment], to base: String) -> String {
        let missing = fragments.filter { !base.contains(flatten($0.text)) }
        guard !missing.isEmpty else { return base }
        return base + "\n\n" + block(missing)
    }

    // MARK: - Live preset composition (the seam both realtime backends share)

    /// Resolve a conflict between the selected preset and the configured general system prompt in
    /// the preset's favour.
    ///
    /// The configured prompt is the user's, and it is shared by every preset and by Direct mode, so
    /// rewriting it to suit one preset would be the wrong repair. It also disagrees with this
    /// contract in ordinary ways — it asks for two-to-four-sentence answers, carries its own
    /// brevity guidelines, and offers to copy text to a clipboard. Ordering settles most of it (the
    /// preset prefix is first), and this note settles the rest by saying which side wins out loud.
    static let precedenceNote = """
    PRECEDENCE:
    The blind-assistance rules above override any later guidance in this prompt about response \
    length, level of detail, chattiness, or what the user can see on a screen. Where two \
    instructions disagree, follow the blind-assistance rule.
    """

    /// Build a realtime backend's base instruction: the selected preset's prefix, the configured
    /// system prompt, and — only under the Blind Assistant preset — the precedence note.
    ///
    /// Extracted as a pure function because neither `GeminiLiveSessionManager` nor
    /// `OpenAIRealtimeSessionManager` can be constructed in a headless test, and because the two
    /// had already drifted: the OpenAI builder applied no preset at all, so selecting Blind
    /// Assistant and connecting to that backend silently got the generic assistant. One function
    /// means the composition order is the same on both by construction, not by review.
    static func composeLiveInstruction(modePrefix: String, basePrompt: String, modeID: String) -> String {
        let prompt = modePrefix + basePrompt
        guard modeID == presetID else { return prompt }
        return prompt + "\n\n" + precedenceNote
    }

    // MARK: - Helpers

    /// Collapse a Swift multi-line string continuation into one line, so a fragment reads as a
    /// single bullet and so `applying(_:to:)`'s containment check compares like with like however
    /// the source happens to be wrapped.
    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
