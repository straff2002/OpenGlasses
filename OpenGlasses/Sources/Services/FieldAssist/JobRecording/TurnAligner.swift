import Foundation

/// Finds when a logged turn was really said (Plan HE §2).
///
/// The job log stamps a technician's turn when the turn is written down, after the words have been
/// heard and transcribed, so the stamp is late by however long that took. The recording's own
/// transcript knows when words were spoken. This matches each logged turn to the utterances shortly
/// before its stamp that hold the same words and moves the turn to where they begin. A turn that
/// matches nothing keeps its log time and says so (`coarse`). It never guesses.
///
/// The assistant's turns are never matched: its replies are not reliably in the audio.
enum TurnAligner {

    struct LoggedTurn: Equatable, Sendable {
        /// The turn's id in the job log.
        let ref: String
        let speaker: String
        /// The job log's stamp, placed on the session clock.
        let stamp: SessionTime
        let text: String
    }

    struct Configuration: Equatable, Sendable {
        /// How far before a turn's stamp its words may have begun.
        var lookBack = SessionTime(milliseconds: 60_000)
        /// How far after the stamp an utterance may end and still be the turn: the two clocks are
        /// joined through the wall clock, which is not exact.
        var slack = SessionTime(milliseconds: 1_000)
        /// The share of an utterance's words that must be in the turn for it to be part of it.
        var utteranceShare = 0.6
        /// The share of the turn's words the matched utterances must hold between them.
        var turnShare = 0.5

        static let standard = Configuration()
    }

    struct Alignment: Equatable, Sendable {
        let turn: LoggedTurn
        /// Where the turn's words begin when aligned; the log's stamp when not.
        let t: SessionTime
        let precision: SessionTimeline.Precision
        /// The utterances the turn was matched to, in order. Empty when coarse.
        let utteranceIDs: [String]

        /// The turn as the timeline records it.
        var event: SessionTimeline.Event {
            SessionTimeline.Event(t: t, kind: .turnLogged, ref: turn.ref, text: turn.text,
                                  speaker: turn.speaker, precision: precision)
        }
    }

    /// One alignment for each turn, in the order the turns were given. Turns are matched in the
    /// order they were stamped, and an utterance is given to one turn only, so two turns with the
    /// same words ("yes", "yes") do not both land on the first one.
    static func align(_ turns: [LoggedTurn], to transcript: TimedTranscript,
                      configuration: Configuration = .standard) -> [Alignment] {
        let utterances = transcript.utterances
        let utteranceWords = utterances.map { Set(RecordingText.words($0.text)) }
        var claimed: Set<Int> = []
        var results: [Int: Alignment] = [:]
        let order = turns.indices.sorted { a, b in
            turns[a].stamp != turns[b].stamp ? turns[a].stamp < turns[b].stamp : a < b
        }
        for index in order {
            let turn = turns[index]
            let coarse = Alignment(turn: turn, t: turn.stamp, precision: .coarse, utteranceIDs: [])
            let words = Set(RecordingText.words(turn.text))
            guard turn.speaker == SessionTimeline.Speaker.technician, !words.isEmpty else {
                results[index] = coarse
                continue
            }
            // Utterances near enough in time that are mostly made of the turn's words.
            let fitting = utterances.indices.filter { i in
                guard !claimed.contains(i), !utteranceWords[i].isEmpty,
                      utterances[i].start >= turn.stamp - configuration.lookBack,
                      utterances[i].end <= turn.stamp + configuration.slack else { return false }
                let shared = utteranceWords[i].intersection(words).count
                return Double(shared) >= configuration.utteranceShare * Double(utteranceWords[i].count)
            }
            // From each of them, back over the utterances just before it for as long as each adds
            // words of the turn. The best run holds the most of the turn's words, and of two
            // equally good the later one is nearer the stamp.
            var best: (run: [Int], shared: Int)?
            for end in fitting {
                var run = [end]
                var covered = utteranceWords[end].intersection(words)
                var earlier = end - 1
                while fitting.contains(earlier) {
                    let added = utteranceWords[earlier].intersection(words).subtracting(covered)
                    if added.isEmpty { break }
                    covered.formUnion(added)
                    run.insert(earlier, at: 0)
                    earlier -= 1
                }
                if covered.count >= (best?.shared ?? 0) { best = (run, covered.count) }
            }
            guard let best, Double(best.shared) >= configuration.turnShare * Double(words.count),
                  let first = best.run.first else {
                results[index] = coarse
                continue
            }
            claimed.formUnion(best.run)
            results[index] = Alignment(turn: turn, t: utterances[first].start, precision: .aligned,
                                       utteranceIDs: best.run.map { utterances[$0].id })
        }
        return turns.indices.compactMap { results[$0] }
    }
}
