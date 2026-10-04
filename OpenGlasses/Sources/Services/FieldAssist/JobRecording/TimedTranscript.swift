import Foundation

/// What was said in a recording and when: a list of utterances, each with the time it began and
/// ended (Plan GY's pipeline; Contracts/recorded-session.md §5, `transcript.json` version 1).
///
/// It comes from speech-to-text and nobody has checked it. Every utterance has an id so that
/// anything built on the transcript — an action event, an index row — can point back at the words;
/// an office that transcribes again keeps the phone's ids for whatever it refers back to.
struct TimedTranscript: Equatable, Sendable {
    static let version = 1

    struct Utterance: Equatable, Codable, Sendable {
        let id: String
        let start: SessionTime
        let end: SessionTime
        let text: String
        let speaker: String?

        init(id: String = "", start: SessionTime, end: SessionTime, text: String, speaker: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }

    /// In time order: by start, then end, then as given.
    let utterances: [Utterance]

    init(utterances: [Utterance]) {
        self.utterances = utterances.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// A transcript whose utterances are numbered `u1`, `u2`, … in time order, whatever ids they
    /// came with. This is how the phone names utterances when it first transcribes a recording.
    static func numbered(_ utterances: [Utterance]) -> TimedTranscript {
        let ordered = TimedTranscript(utterances: utterances).utterances
        return TimedTranscript(utterances: ordered.enumerated().map { index, u in
            Utterance(id: "u\(index + 1)", start: u.start, end: u.end, text: u.text, speaker: u.speaker)
        })
    }

    /// The same words moved along the clock: a part transcribed from its own first sample is
    /// placed on the session's clock by the part's `tZero`.
    func shifted(by offset: SessionTime) -> TimedTranscript {
        TimedTranscript(utterances: utterances.map {
            Utterance(id: $0.id, start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker)
        })
    }

    func utterance(id: String) -> Utterance? {
        utterances.first { $0.id == id }
    }
}

// MARK: - transcript.json

extension TimedTranscript {
    enum Refusal: Error, Equatable {
        /// Not JSON, not the shape version 1 gives a transcript, an utterance with no id or one
        /// that ends before it starts, or two utterances with the same id.
        case malformed
    }

    private struct File: Codable {
        let utterances: [Utterance]
    }

    /// The bytes of `transcript.json`. A transcript whose ids would not read back is not written.
    func encoded() throws -> Data {
        guard Self.soundIDs(utterances) else { throw Refusal.malformed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(utterances: utterances))
    }

    /// Reads a version 1 transcript. Members this version does not know are passed over. An id
    /// must be there and must be the only one of its name: it is what everything else points at.
    static func decode(_ data: Data) throws -> TimedTranscript {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { throw Refusal.malformed }
        guard soundIDs(file.utterances), file.utterances.allSatisfy({ $0.start <= $0.end }) else {
            throw Refusal.malformed
        }
        return TimedTranscript(utterances: file.utterances)
    }

    private static func soundIDs(_ utterances: [Utterance]) -> Bool {
        var seen: Set<String> = []
        return utterances.allSatisfy { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
}
