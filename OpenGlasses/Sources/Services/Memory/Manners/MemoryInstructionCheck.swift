import Foundation

/// Instructions are not facts, and text the wearer is only processing is not the wearer
/// (Plan LN §3). Pure.
///
/// Two rules, applied before a fact's subject matter is looked at:
///
/// 1. **A turn that read untrusted output is not a source of inferred facts.** When a tool whose
///    output is untrusted ran in the turn (`PromptInjectionPolicy.isUntrustedOutput`: the web,
///    OCR, translation, captions, mail, an MCP server, the gateway), an *inferred* tag in that
///    turn's reply is dropped. What a page, a sign, a translated letter or a bystander's sentence
///    says is not something the wearer told us. A told-me tag in the same turn ("remember this
///    wifi password from the sign") still goes on to the subject-matter rules.
/// 2. **A memory that makes the assistant less careful is never kept, whoever proposes it** — one
///    to approve on its own, warn less, agree more, skip a confirmation, or set aside its
///    instructions. An *inferred* value shaped as any instruction to the assistant is dropped
///    too ("always…", "from now on…", or a mention of confirming, approving, warning, agreeing,
///    the system prompt or earlier instructions). A told-me preference about format ("keep
///    answers short", "always use metric") is kept: it changes how an answer is said, not how
///    carefully the assistant acts.
enum MemoryInstructionCheck {

    /// The reason a write may not be kept, or nil when this check has nothing against it.
    static func reason(key: String, value: String, origin: MemoryOrigin,
                       turnReadUntrustedOutput: Bool) -> MemorySensitivity.Category? {
        let told = origin == .toldMe
        if !told, turnReadUntrustedOutput { return .untrustedSource }
        let text = key.isEmpty ? value : "\(key) \(value)"
        if weakensSafeguards(text) { return .assistantInstruction }
        if !told, isInstructionShaped(value) { return .assistantInstruction }
        return nil
    }

    // MARK: - Weakening a safeguard (any origin)

    private static let weakeningPatterns: [NSRegularExpression] = [
        // Approving, confirming or paying on its own.
        #"\bauto ?approv\w*"#,
        #"\bautomatically (approv|confirm|accept|send|pay|authori[sz])\w*"#,
        #"\b(approv|confirm|accept|authori[sz])\w* (\w+ ){0,3}automatically\b"#,
        #"\bapprove (everything|all|anything)\b"#,
        // Not asking, checking, confirming or warning.
        #"\b(dont|do not|never|no need to|stop|quit|no more) (\w+ ){0,3}(ask|asking|confirm\w*|check\w*|double check\w*|warn\w*|verify\w*|caution\w*|disclaimer\w*)\b"#,
        #"\b(skip|skipping|bypass\w*|disable\w*|turn off|ignore|ignoring|drop) (\w+ ){0,3}(confirm\w*|check\w*|warn\w*|approv\w*|safety|instructions?|rules?|guard\w*|verification|safeguard\w*|disclaimer\w*)\b"#,
        #"\bwithout (\w+ ){0,2}(ask\w*|confirm\w*|check\w*|warn\w*|approv\w*|verif\w*)\b"#,
        // Agreeing more.
        #"\balways (\w+ ){0,2}(agree\w*|approve\w*|say yes|accept\w*|go along)\b"#,
        #"\bagree with (me|everything|the user|whatever)\b"#,
        #"\btell (me|the user|them) what (i|they) want to hear\b"#,
        // Setting its instructions aside.
        #"\b(system prompt|developer message|(previous|prior|earlier|original|your) instructions)\b"#,
        #"\b(ignore|disregard|forget|override) (all|any|the|your|previous|prior|earlier) (\w+ ){0,2}(instructions?|rules?|guidelines?|polic\w*)\b"#,
        // Less careful, less honest.
        #"\b(be )?less careful\b"#,
        #"\blie to (me|the user)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Whether the text asks the assistant to approve on its own, warn or check less, agree more,
    /// or set its instructions aside.
    static func weakensSafeguards(_ text: String) -> Bool {
        let words = plain(text)
        let range = NSRange(words.startIndex..., in: words)
        return weakeningPatterns.contains { $0.firstMatch(in: words, range: range) != nil }
    }

    // MARK: - Shaped as an instruction (inferred only)

    private static let imperativeOpeners: [String] = [
        "always ", "never ", "from now on", "ignore ", "dont ask", "do not ask", "skip ", "stop ",
        "you must", "you should", "you need to", "the assistant should", "assistant should",
        "make sure you", "remember to always",
    ]

    private static let instructionTopics = try? NSRegularExpression(
        pattern: #"\b(confirm\w*|approv\w*|warn\w*|agree\w*|system prompt|(previous|prior|earlier) instructions)\b"#)

    /// An imperative opener, or a mention of confirming, approving, warning, agreeing, the system
    /// prompt or earlier instructions.
    static func isInstructionShaped(_ value: String) -> Bool {
        let words = plain(value)
        if imperativeOpeners.contains(where: words.hasPrefix) { return true }
        guard let instructionTopics else { return false }
        return instructionTopics.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
    }

    /// Lower-cased, apostrophes dropped, other punctuation to spaces, whitespace collapsed.
    private static func plain(_ text: String) -> String {
        MemorySensitivity.normalisedWords(text).trimmingCharacters(in: .whitespaces)
    }
}
