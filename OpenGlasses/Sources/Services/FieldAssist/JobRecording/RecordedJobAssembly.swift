import Foundation

/// Puts a recorded job's timeline and transcript together when the recording stops (Plan HE §2).
///
/// Three kinds of thing land on the one clock:
///
/// - **the media** — each recorded part, placed by the recorder's own readings
///   (`RecordingTimebase`), with the gaps between parts written down;
/// - **what was noted as it happened** — the microphone going live, the assistant starting and
///   stopping speaking, the capture being silenced, a tool being called, the technician marking a
///   moment. These carry the monotonic time they were noted at;
/// - **what the job log wrote down** — turns, photographs, procedure steps. The log stamps with
///   the wall clock, and stamps a turn after it was heard, so a technician's turn is moved to where
///   its words are in the transcript when they can be found (`TurnAligner`) and marked `coarse`
///   when they cannot.
///
/// Then the candidate markers, from the transcript's step-like segments and the events.
///
/// Pure: everything is an input, and the same inputs give the same two files.
enum RecordedJobAssembly {

    /// One line of the job log that belongs on the timeline.
    struct LogEntry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A turn the log wrote down, with the log's own id for it when it has one.
            case technicianTurn(ref: String?, text: String)
            case assistantTurn(ref: String?, text: String)
            case photo(ref: String?)
            case procedureStarted(procedureID: String?)
            case procedureStep(stepID: String?)
            case procedureCompleted(procedureID: String?)
        }

        /// The log's stamp.
        let at: Date
        let kind: Kind

        init(at: Date, kind: Kind) {
            self.at = at
            self.kind = kind
        }
    }

    struct Assembled: Equatable, Sendable {
        let timeline: SessionTimeline
        let transcript: TimedTranscript
    }

    /// The words of one part, timed from that part's own first audio sample, as a transcriber
    /// gives them.
    struct PartWords: Equatable, Sendable {
        let partID: String
        let utterances: [TimedTranscript.Utterance]

        init(partID: String, utterances: [TimedTranscript.Utterance]) {
            self.partID = partID
            self.utterances = utterances
        }
    }

    /// The transcript of the whole recording: each part's words moved to where that part's sound
    /// begins on the session clock, and the utterances numbered in time order. Words for a part
    /// with no sound on the timeline are left out — there is nowhere to put them.
    static func transcript(_ words: [PartWords], parts: [RecordingTimebase.PlacedPart]) -> TimedTranscript {
        var all: [TimedTranscript.Utterance] = []
        for item in words {
            guard let audio = parts.first(where: { $0.partID == item.partID })?.audio else { continue }
            for utterance in TimedTranscript(utterances: item.utterances).shifted(by: audio.tZero).utterances {
                let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, utterance.start <= utterance.end else { continue }
                // Words cannot run past the sound they were heard in.
                all.append(.init(start: min(utterance.start, audio.end), end: min(utterance.end, audio.end),
                                 text: text, speaker: utterance.speaker))
            }
        }
        return TimedTranscript.numbered(all)
    }

    /// The timeline and the transcript of a recording.
    ///
    /// - Parameters:
    ///   - clock: the session's zero.
    ///   - parts: every recorded part, placed.
    ///   - noted: events noted as they happened, already on the session clock.
    ///   - log: the job log's lines. Only those stamped while the recording ran are used.
    ///   - endedAt: when the recording stopped, on the session clock.
    ///   - blurred: what the face blur did to each part it went through, when the organisation
    ///     requires it. Where it left the video without a picture there is a `filter` gap.
    static func assemble(clock: SessionClock, parts: [RecordingTimebase.PlacedPart],
                         noted: [SessionTimeline.Event], log: [LogEntry], words: [PartWords],
                         endedAt: SessionTime, blurred: [BlurredPart] = []) -> Assembled {
        let transcript = Self.transcript(words, parts: parts)
        let placed = RecordingTimebase.tracksAndGaps(parts)
        let gaps = BlurredPart.timelineGaps(between: placed.gaps, blurred: blurred)
        let end = max(endedAt, parts.compactMap(\.end).max() ?? .zero)
        func inside(_ time: SessionTime) -> Bool { time >= .zero && time <= end }

        var events = noted.filter { inside($0.t) }
        var turns: [TurnAligner.LoggedTurn] = []
        for (index, entry) in log.enumerated() {
            let t = clock.time(wall: entry.at)
            guard inside(t) else { continue }
            switch entry.kind {
            case let .technicianTurn(ref, text):
                turns.append(.init(ref: ref ?? "log-\(index + 1)", speaker: SessionTimeline.Speaker.technician,
                                   stamp: t, text: text))
            case let .assistantTurn(ref, text):
                turns.append(.init(ref: ref ?? "log-\(index + 1)", speaker: SessionTimeline.Speaker.assistant,
                                   stamp: t, text: text))
            case let .photo(ref):
                events.append(.init(t: t, kind: .photo, ref: ref))
            case let .procedureStarted(id):
                events.append(.init(t: t, kind: .procedureStarted, ref: id))
            case let .procedureStep(id):
                events.append(.init(t: t, kind: .procedureStep, ref: id))
            case let .procedureCompleted(id):
                events.append(.init(t: t, kind: .procedureCompleted, ref: id))
            }
        }
        events += TurnAligner.align(turns, to: transcript).map(\.event)

        var timeline = SessionTimeline(wallStart: clock.wallStartMilliseconds, tracks: placed.tracks,
                                       gaps: gaps, events: events)
        timeline.candidates = ProcedureCandidateDetector.candidates(
            timeline: timeline, segments: WalkthroughSegmenter.segments(transcript))
        return Assembled(timeline: timeline.normalized(), transcript: transcript)
    }
}
