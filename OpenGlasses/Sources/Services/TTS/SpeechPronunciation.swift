import Foundation

/// Pronunciation aliases for audio only; transcripts and HUD text retain the brand spelling.
enum SpeechPronunciation {
    static let liveVoiceInstruction = """
    BRAND PRONUNCIATION:
    Pronounce Avenkin as three syllables: Ah-Ven-Kin. In Avenkin AI, say the letters A and I \
    separately after the name. Keep the written spelling Avenkin AI in transcripts.
    """

    private static let brand = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])avenkin([ \t]*ai)?(?![\p{L}\p{N}_])"#)

    static func spokenForm(of text: String) -> String {
        let source = text as NSString
        var result = text
        // Replace from the end so each range continues to refer to the original string.
        for match in brand.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let name = match.range(at: 1).location == NSNotFound ? "Ah-Ven-Kin" : "Ah-Ven-Kin A I"
            result.replaceSubrange(range, with: name)
        }
        return result
    }
}
