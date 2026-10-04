import Foundation

/// The index that ties a step to the words and the stretch of video that go with it
/// (Contracts/recorded-session.md §7.4).
///
/// One row for each validated event, and one for each stretch of video under a step that was said
/// and not seen. A row points at media by part and time, never by file, so it still means
/// something when the media has been archived or deleted. A row never spans a gap.
///
/// Built from the timeline, the transcript and the validated events and from nothing else: the same
/// three give the same rows in the same order. Reference code for a rule both sides compute the
/// same way; `Contracts/fixtures/cross-reference-v1.json` holds the case.
enum CrossReferenceIndex {

    struct Step: Equatable, Codable, Sendable {
        let procedureID: String
        let stepID: String
    }

    struct Video: Equatable, Codable, Sendable {
        let partID: String
        let from: SessionTime
        let to: SessionTime
    }

    struct Row: Equatable, Codable, Sendable {
        /// `e-` and the event's id, or `s-`, the segment's id, `-` and which piece of video this is.
        let rowID: String
        /// The procedure step the runner was on when the row begins, when a procedure was running.
        let step: Step?
        let utterances: [String]
        let video: Video
        let keyframes: [ActionEvent.Moment]
        let events: [String]
        let agreement: SpeechAgreement.Label
    }

    static func build(timeline: SessionTimeline, transcript: TimedTranscript, events: [ActionEvent]) -> [Row] {
        let clear = timeline.clearSpans(.video)
        let agreement = SpeechAgreement.assess(events: events, transcript: transcript)
        let steps = stepChanges(timeline)
        func step(at time: SessionTime) -> Step? {
            steps.last { $0.t <= time }?.step
        }

        var rows: [Row] = []
        for (event, seen) in zip(events, agreement.seen) {
            // An event that is not wholly on one clear stretch of video gets no row. Validation
            // lets none through; this keeps the promise for events that came some other way.
            guard let span = clear.first(where: { $0.from <= event.start && event.end <= $0.to }) else { continue }
            rows.append(Row(rowID: "e-\(event.id)", step: step(at: event.start), utterances: seen.utterances,
                            video: Video(partID: span.partID, from: event.start, to: event.end),
                            keyframes: event.evidence, events: [event.id], agreement: seen.label))
        }
        for unseen in agreement.unseen {
            // The video under the words, cut where the video is cut. Words said while nothing was
            // being recorded have no clip, and so no row.
            let pieces = clear.compactMap { span -> Video? in
                let from = max(span.from, unseen.from)
                let to = min(span.to, unseen.to)
                return from < to ? Video(partID: span.partID, from: from, to: to) : nil
            }
            for (number, video) in pieces.enumerated() {
                rows.append(Row(rowID: "s-\(unseen.segmentID)-\(number + 1)", step: step(at: video.from),
                                utterances: unseen.utterances, video: video, keyframes: [], events: [],
                                agreement: .saidNotSeen))
            }
        }
        return rows.sorted { a, b in
            a.video.from != b.video.from ? a.video.from < b.video.from
                : a.rowID.utf8.lexicographicallyPrecedes(b.rowID.utf8)
        }
    }

    /// Each moment the procedure runner's step changed, in time order: a step being reached, or —
    /// with no step — a procedure starting or finishing.
    private static func stepChanges(_ timeline: SessionTimeline) -> [(t: SessionTime, step: Step?)] {
        var changes: [(t: SessionTime, step: Step?)] = []
        var procedure: String?
        for event in timeline.normalized().events {
            switch event.kind {
            case .procedureStarted:
                procedure = event.ref
                changes.append((event.t, nil))
            case .procedureStep:
                if let procedure, let stepID = event.ref {
                    changes.append((event.t, Step(procedureID: procedure, stepID: stepID)))
                }
            case .procedureCompleted:
                procedure = nil
                changes.append((event.t, nil))
            default:
                break
            }
        }
        return changes
    }
}
