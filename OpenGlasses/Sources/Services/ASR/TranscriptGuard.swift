import Foundation

/// Plan BS P1 — silence/artifact protection for speech recognition (pure).
///
/// Speech models of this family have a well-known failure mode: silence or noise decodes
/// as training-corpus boilerplate (news sign-offs, subtitle credits — frequently CJK text
/// for models trained on Asian corpora). A hallucinated transcript doesn't just look
/// wrong: captions feed meeting summaries, the Spotlight index (BQ), and Brain ingestion.
///
/// Two independent defenses, both deliberately conservative (when in doubt, keep the
/// transcript):
/// - `passesEnergyGate`: skip recognition entirely when the buffer is effectively silent.
/// - `filter`: drop recognized text matching unmistakable artifact shapes only —
///   degenerate repetition, known boilerplate, and script mismatch (CJK output when the
///   configured recognition locale isn't CJK; an "auto" locale skips the script rule).
enum TranscriptGuard {

    // MARK: Energy gate (pre-recognition)

    /// RMS threshold ≈ -50 dBFS: comfortably below quiet speech, above electrical noise.
    static let defaultRMSThreshold: Float = 0.003

    static func passesEnergyGate(samples: [Float], rmsThreshold: Float = defaultRMSThreshold) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms >= rmsThreshold
    }

    // MARK: Artifact filter (post-recognition)

    /// Boilerplate shapes seen from silence decodes across this model family: broadcast
    /// sign-offs, subtitle-credit lines, video-platform boilerplate. Substring match on
    /// the trimmed transcript, case-insensitive where scripts have case.
    private static let boilerplatePatterns: [String] = [
        "뉴스",                      // Korean "news" — the classic sign-off artifact
        "구독",                      // Korean "subscribe"
        "시청해주셔서 감사합니다",        // "thanks for watching"
        "ご視聴ありがとうございました",     // Japanese "thanks for watching"
        "字幕",                      // "subtitles" (subtitle-credit artifacts)
        "点赞",                      // "like" (video boilerplate)
        "订阅",                      // "subscribe"
        "amara.org",                // subtitle-community credit
        "thanks for watching",
        "thank you for watching",
        "subscribe to",
    ]

    /// Returns nil when the transcript is an unmistakable artifact; otherwise the
    /// (trimmed) transcript.
    static func filter(_ text: String, expectedLocaleIdentifier: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        for pattern in boilerplatePatterns where lowered.contains(pattern.lowercased()) {
            return nil
        }

        if isDegenerateRepetition(trimmed) { return nil }

        // Script mismatch: majority-CJK output against an explicitly non-CJK locale.
        // Auto/unknown locale → the user may genuinely speak a CJK language; keep it.
        if let locale = expectedLocaleIdentifier,
           locale != "auto",
           !localeIsCJK(locale),
           cjkFraction(of: trimmed) > 0.5 {
            return nil
        }

        return trimmed
    }

    /// Same short token repeated ≥4 times with nothing else ("okay okay okay okay") —
    /// a decode-loop artifact, not speech worth keeping.
    static func isDegenerateRepetition(_ text: String) -> Bool {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard tokens.count >= 4 else { return false }
        return Set(tokens).count == 1
    }

    static func cjkFraction(of text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        // Script ranges live in ScriptAwareJoiner (Plan BY) — one source for "is this CJK",
        // shared with the caption spacing fix, so the two can't drift.
        let cjk = letters.filter { ScriptAwareJoiner.isCJK($0) }
        return Double(cjk.count) / Double(letters.count)
    }

    static func localeIsCJK(_ identifier: String) -> Bool {
        let prefix = identifier.prefix(2).lowercased()
        return ["zh", "ja", "ko", "yu"].contains(String(prefix))
    }
}
