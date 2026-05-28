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

    init?(rawValue: String) {
        switch rawValue.lowercased() {
        case "read": self = .read
        case "simplify": self = .simplify
        case "translate": self = .translate
        case "define": self = .define
        default: return nil
        }
    }

    /// Build the instruction prepended to the OCR text for the main LLM.
    /// `level` and `targetLanguage` default from `ReadingProfile` when nil.
    func directive(level: ReadingProfile.Level? = nil, targetLanguage: String? = nil) -> String {
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
        case .define:
            return """
            READING MODE — DEFINE. Give a plain-language definition of the following term, plus one \
            short usage example. Keep the whole response under 40 words. No markdown.
            """
        }
    }
}
