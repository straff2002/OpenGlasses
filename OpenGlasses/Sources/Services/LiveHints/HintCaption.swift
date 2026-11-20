import Foundation

/// One caption as the live-hints trigger reads it (Plan MO §4): the words, who said them if
/// diarization knows, the language, when, and whether the recogniser has finished with it.
///
/// A value of its own so the trigger stays pure and testable without the caption service.
struct HintCaption: Equatable, Sendable {
    var text: String
    /// The diarized speaker, or nil when voices are not told apart.
    var speaker: Int?
    /// BCP-47, e.g. "en-GB". Decides which question words apply.
    var languageCode: String
    var timestamp: Date
    /// False for an interim line the recogniser may still revise.
    var isFinal: Bool

    init(text: String, speaker: Int? = nil, languageCode: String, timestamp: Date, isFinal: Bool = true) {
        self.text = text
        self.speaker = speaker
        self.languageCode = languageCode
        self.timestamp = timestamp
        self.isFinal = isFinal
    }

    /// A caption from the history. Entries in `captionHistory` are finals. `languageCode` is the
    /// language `entry.text` is written in: the session's recognition language, or for a
    /// translated caption the translation's target (`entry.language` is then the language it was
    /// translated *from*, not the language of the text).
    init(_ entry: AmbientCaptionService.CaptionEntry, languageCode: String, isFinal: Bool = true) {
        self.init(text: entry.text, speaker: entry.speaker,
                  languageCode: languageCode,
                  timestamp: entry.timestamp, isFinal: isFinal)
    }
}
