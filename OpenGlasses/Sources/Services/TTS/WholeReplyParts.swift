import Foundation

/// A finished reply said in parts, so the wearer hears its first sentence while the rest is still
/// being synthesised.
///
/// A cloud voice is asked for a whole utterance at once and nothing plays until every byte of it
/// is back. For a reply of a few paragraphs that is many seconds of silence after the answer is
/// already on the screen (b705 report: "there is already an answer in the chat box, it still waits
/// 10 seconds to read it out"). Sentence streaming (Plan HZ) fixes that only while the model is
/// still writing, and only with its Developer switch on; this fixes it for every reply that is
/// final before it is spoken.
///
/// The first part is the first sentence alone, so the first request is short. The rest are packed
/// up to `laterPartLimit` characters, so a long answer is a handful of requests rather than one per
/// sentence, and the voice keeps its phrasing across the sentences of a part. The parts joined are
/// the reply's own words, in order.
enum WholeReplyParts {

    /// What a later part may grow to before the next sentence starts a new one.
    static let laterPartLimit = 280

    /// The reply split into the parts it is said in. One part means "say it whole, as before".
    static func parts(of reply: String, laterPartLimit: Int = WholeReplyParts.laterPartLimit) -> [String] {
        var splitter = SentenceStreamSplitter()
        let sentences = (splitter.ingest(reply) + splitter.flush())
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = sentences.first else { return [] }
        var parts = [first]
        var current = ""
        for sentence in sentences.dropFirst() {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= laterPartLimit {
                current += " " + sentence
            } else {
                parts.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// How a reply said in parts ended, in the terms `speakReporting` answers with: completed only
    /// when every part played to its end.
    static func outcome(of record: StreamedReplyRecord) -> SpeechDeliveryOutcome {
        if let interruption = record.interruption { return .interrupted(by: interruption) }
        if record.sentenceCount > 0, record.heardCount == record.sentenceCount { return .completed }
        return .failed(reason: "not every part played")
    }
}
