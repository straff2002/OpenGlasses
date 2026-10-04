import Foundation

/// Whether what was seen in a recorded job and what was said agree
/// (Contracts/recorded-session.md §7.3).
///
/// Worked out from the transcript every time. The utterances a model attaches to its own events
/// are its claim and are not used.
///
/// - `confirmed_by_speech`: an utterance within five seconds of the event says, without a
///   negation, at least one of the content words of the event's action, object or tool.
/// - `seen_not_said`: an event with no such utterance.
/// - `said_not_seen`: a step someone said — a step-like segment of the narration — with no event
///   within five seconds of it.
///
/// Reference code for a rule both sides compute the same way; `Contracts/fixtures/agreement-v1.json`
/// holds the cases.
enum SpeechAgreement {
    /// How far apart in time words and an action may be and still be about each other. Exactly
    /// this far counts.
    static let window = SessionTime(milliseconds: 5_000)

    enum Label: String, Codable, Sendable {
        case confirmedBySpeech = "confirmed_by_speech"
        case seenNotSaid = "seen_not_said"
        case saidNotSeen = "said_not_seen"
    }

    /// An event and its label.
    struct Seen: Equatable, Sendable {
        let eventID: String
        let label: Label
        /// Carried from the event. A low-confidence event is labelled like any other and stays
        /// marked: its label is not a fact either.
        let lowConfidence: Bool
        /// The utterances that confirm it, in transcript order. Empty for `seen_not_said`.
        let utterances: [String]
    }

    /// A step that was said and that no event shows. Always `said_not_seen`.
    struct Unseen: Equatable, Sendable {
        let segmentID: String
        let from: SessionTime
        let to: SessionTime
        let utterances: [String]
    }

    struct Result: Equatable, Sendable {
        /// In the order the events were given.
        let seen: [Seen]
        /// In time order.
        let unseen: [Unseen]
    }

    static func assess(events: [ActionEvent], transcript: TimedTranscript) -> Result {
        let said = transcript.utterances.map { RecordingText.affirmedStems($0.text) }
        let seen = events.map { event -> Seen in
            let wanted = RecordingText.contentStems([event.action, event.object, event.tool].compactMap { $0 }
                .joined(separator: " "))
            let confirming = transcript.utterances.indices.filter { index in
                near(transcript.utterances[index].start, transcript.utterances[index].end, event.start, event.end)
                    && !said[index].isDisjoint(with: wanted)
            }.map { transcript.utterances[$0].id }
            return Seen(eventID: event.id, label: confirming.isEmpty ? .seenNotSaid : .confirmedBySpeech,
                        lowConfidence: event.lowConfidence, utterances: confirming)
        }
        let unseen = WalkthroughSegmenter.segments(transcript).filter { segment in
            segment.isStepLike && !events.contains { near($0.start, $0.end, segment.start, segment.end) }
        }.map { Unseen(segmentID: $0.id, from: $0.start, to: $0.end, utterances: $0.utteranceIDs) }
        return Result(seen: seen, unseen: unseen)
    }

    /// Whether two stretches of time overlap once one of them is widened by the window at each end.
    static func near(_ aStart: SessionTime, _ aEnd: SessionTime, _ bStart: SessionTime, _ bEnd: SessionTime) -> Bool {
        aEnd >= bStart - window && aStart <= bEnd + window
    }
}
