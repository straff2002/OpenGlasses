import Foundation

/// The four Reading Accessibility transforms (A1), adapted from the `brain` project.
///
/// `ReadingAccessibilityTool` OCRs text on-device, then returns a mode-specific directive plus the
/// extracted text. The main conversation LLM applies the transform and its reply streams to TTS —
/// matching how `TranslationTool` / `DocumentScanTool` already work in this codebase.
enum ReadingMode: String, CaseIterable {
    case read
    case simplify
    case translate
    case define
    case ask

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "read": self = .read
        case "simplify": self = .simplify
        case "translate": self = .translate
        case "define": self = .define
        case "ask", "answer", "question": self = .ask
        default: return nil
        }
    }

    /// Build the instruction prepended to the OCR text for the main LLM.
    /// `level` and `targetLanguage` default from `ReadingProfile` when nil.
    ///
    /// Every mode carries the shared blind-assistance reading fragments (Plan FF P0), including
    /// the transforming ones. Simplifying and translating are exactly where a model is most
    /// tempted to smooth a gap shut — a missing dosage becomes a plausible dosage — and the wearer
    /// cannot look down and check. The mode's own directive still owns the output shape.
    func directive(level: ReadingProfile.Level? = nil, targetLanguage: String? = nil) -> String {
        BlindAssistanceContract.applying(BlindAssistanceContract.readingFragments,
                                         to: modeDirective(level: level, targetLanguage: targetLanguage))
    }

    private func modeDirective(level: ReadingProfile.Level?, targetLanguage: String?) -> String {
        switch self {
        case .read:
            return """
            READING MODE — READ ALOUD. The following text was captured via OCR and may contain \
            artifacts. Clean it up: fix obvious OCR errors, drop stray characters and page noise, and \
            preserve the original meaning and order. Output only the cleaned text, suitable for being \
            spoken aloud. No markdown, no commentary.
            """
        case .simplify:
            let audience = (level ?? ReadingProfile.level).audienceDescription
            return """
            READING MODE — SIMPLIFY. Rewrite the following text so it is easy to understand for \
            \(audience). Preserve the full meaning, but adjust vocabulary and sentence length to suit \
            that reader. Output only the rewritten text. No markdown, no commentary.
            """
        case .translate:
            let code = targetLanguage ?? ReadingProfile.preferredLanguage
            let name = ReadingProfile.languageName(for: code)
            return """
            READING MODE — TRANSLATE. Translate the following text into \(name). Preserve tone and \
            meaning. Output only the translated text. No markdown, no commentary.
            """
        case .ask:
            // Grounding + abstention: a low-vision user can't verify the answer, so a confident
            // invention is worse than "I can't find it".
            return """
            READING MODE — ANSWER FROM CAPTURED TEXT. The user asked a question about text their \
            glasses camera captured (below). They may not be able to verify what you say, so answer \
            using ONLY the captured text: give the direct answer first, then one brief supporting \
            detail if it is present. If the answer is not in the captured text, say you can't find \
            it and suggest repositioning the glasses — do NOT guess or add anything that isn't \
            there. Reply in one or two natural spoken sentences. No markdown, no commentary.
            """
        case .define:
            return """
            READING MODE — DEFINE. Give a plain-language definition of the following term, plus one \
            short usage example. Keep the whole response under 40 words. No markdown.
            """
        }
    }
}
