import Foundation

/// Marks where in a recorded job a procedure probably took place (Plan HE §2), so the office knows
/// where to look first.
///
/// Advice only. The phone does nothing with a candidate but write it into the timeline, and the
/// office is free to ignore it and to look anywhere else.
///
/// - `certain`: the procedure runner was running (from `procedure_started` to
///   `procedure_completed`, or to the last step reached when it was never completed), or the
///   technician said to mark the moment.
/// - `likely`: three or more step-like stretches of narration, each beginning soon after the one
///   before. Stretches that are not step-like may lie between them.
enum ProcedureCandidateDetector {

    struct Configuration: Equatable, Sendable {
        /// How many step-like segments make a run.
        var minimumSteps = 3
        /// A step that begins later than this after the previous one ended starts a new run.
        var maximumStepSpacing = SessionTime(milliseconds: 180_000)
        /// How far around a spoken marker the candidate reaches. "Mark that" may be about what was
        /// just done or what is about to be.
        var markerLead = SessionTime(milliseconds: 30_000)
        var markerTrail = SessionTime(milliseconds: 30_000)

        static let standard = Configuration()
    }

    enum Reason {
        static let procedureRun = "procedure_run"
        static let userMarker = "user_marker"
        static let stepRun = "step_run"
    }

    static func candidates(timeline: SessionTimeline, segments: [WalkthroughSegmenter.Segment],
                           configuration: Configuration = .standard) -> [SessionTimeline.Candidate] {
        let events = timeline.normalized().events
        var certain: [SessionTimeline.Candidate] = []

        // Runs of the procedure runner.
        var runStart: SessionTime?
        var lastStep: SessionTime?
        func closeRun(at end: SessionTime?) {
            if let from = runStart, let to = end ?? lastStep, from < to {
                certain.append(.init(from: from, to: to, certainty: .certain, reason: Reason.procedureRun))
            }
            runStart = nil
            lastStep = nil
        }
        for event in events {
            switch event.kind {
            case .procedureStarted:
                closeRun(at: nil)
                runStart = event.t
            case .procedureStep where runStart != nil:
                lastStep = event.t
            case .procedureCompleted where runStart != nil:
                closeRun(at: event.t)
            default:
                break
            }
        }
        closeRun(at: nil)

        // Moments the technician marked, kept inside the recording when its extent is known.
        let recordedEnd = timeline.tracks.flatMap(\.parts).map(\.end).max()
        for event in events where event.kind == .userMarker {
            let from = max(SessionTime.zero, event.t - configuration.markerLead)
            let to = min(recordedEnd ?? event.t + configuration.markerTrail, event.t + configuration.markerTrail)
            if from < to {
                certain.append(.init(from: from, to: to, certainty: .certain, reason: Reason.userMarker))
            }
        }

        // Runs of narrated steps. One that lies wholly inside a certain candidate adds nothing.
        var likely: [SessionTimeline.Candidate] = []
        var run: [WalkthroughSegmenter.Segment] = []
        func closeSteps() {
            if run.count >= configuration.minimumSteps, let first = run.first, let last = run.last {
                let candidate = SessionTimeline.Candidate(from: first.start, to: last.end, certainty: .likely,
                                                          reason: Reason.stepRun)
                if !certain.contains(where: { $0.from <= candidate.from && candidate.to <= $0.to }) {
                    likely.append(candidate)
                }
            }
            run = []
        }
        for segment in segments where segment.isStepLike {
            if let last = run.last, segment.start - last.end > configuration.maximumStepSpacing { closeSteps() }
            run.append(segment)
        }
        closeSteps()

        return SessionTimeline(wallStart: timeline.wallStart, candidates: certain + likely).normalized().candidates
    }
}
