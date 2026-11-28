import Foundation

/// Whether a "show me" is a meter's reading said aloud rather than a request to see something. Pure.
///
/// Build 799: the technician said "the voltage shows me 125 V" and speech recognition wrote "the
/// voltage show me 125 V". The turn classifier took "show me" as a page request and opened the
/// search's best guess (an unrelated vent-length table), and the camera detector took it as a
/// request to look and sent a glasses photo with the turn.
///
/// A readout has something before the phrase (the instrument or the quantity: "the meter", "the
/// voltage", "it") and a number straight after it, past at most one hedge ("about", "like"), with
/// or without a unit glued on ("125", "125v", "3.2"). A "show me" with nothing before it but the
/// asking ("can you show me 47", "show me 47") stays a request, as does one followed by a word
/// ("show me page 47", "show me the table").
enum ShowMeReadout {

    /// The phrase as heard, in its forms ("shows me" when recognition gets it right).
    static let phrases: [[String]] = [["show", "me"], ["shows", "me"], ["showing", "me"], ["showed", "me"]]

    /// Words before the phrase that are only the asking, not an instrument or a quantity.
    private static let askingWords: Set<String> = [
        "can", "could", "would", "will", "you", "please", "just", "now", "ok", "okay", "so", "hey",
        "um", "uh", "er", "erm", "and", "then", "go", "ahead", "yeah", "right",
    ]

    /// Hedges a technician puts between the phrase and the number.
    private static let hedges: Set<String> = [
        "about", "around", "like", "roughly", "approximately", "nearly", "almost", "only", "just",
        "over", "under", "maybe", "exactly", "a", "minus", "negative",
    ]

    /// Whether `text` says a reading with "show me" in it.
    static func isReadout(_ text: String) -> Bool {
        isReadout(words: ManualTurnClassifier.words(text))
    }

    /// The same, on words already lowercased and split the way `ManualTurnClassifier.words` does.
    static func isReadout(words: [String]) -> Bool {
        for start in words.indices {
            guard let phrase = phrases.first(where: { matches($0, in: words, at: start) }) else { continue }
            let before = words[..<start]
            guard before.contains(where: { !askingWords.contains($0) }) else { continue }
            var next = start + phrase.count
            if next < words.count, hedges.contains(words[next]) { next += 1 }
            if next < words.count, isNumberWithUnit(words[next]) { return true }
        }
        return false
    }

    private static func matches(_ phrase: [String], in words: [String], at start: Int) -> Bool {
        guard start + phrase.count <= words.count else { return false }
        return Array(words[start..<(start + phrase.count)]) == phrase
    }

    /// "125", "3.2", "1,200", or one with a short unit glued on: "125v", "3.2a", "40psi".
    static func isNumberWithUnit(_ word: String) -> Bool {
        word.range(of: #"^\d+(?:[.,]\d+)*[a-zµΩω°%]{0,4}$"#, options: .regularExpression) != nil
    }
}
