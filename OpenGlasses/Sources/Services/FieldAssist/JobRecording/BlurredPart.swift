import Foundation

/// What blurring one recorded part came to, and where it left the video without a picture
/// (Plan HE §1, "Blur when required"; Contracts/recorded-session.md §3 `droppedFrames`, §4 `filter`).
///
/// Where the organisation requires faces blurred, every picture of a recorded part goes through
/// the face blur before the bundle is sealed. A picture the blur cannot process is left out, never
/// written as it was — so a blurred part can be short of pictures, and this is the record of how
/// short: how many were written, how many were dropped, and the stretches of the session where
/// enough were dropped in a row that there is no picture to speak of.
///
/// Pure: the pass that does the work reports in the part's own time (`Report`), and this places
/// the report on the session's clock and writes the timeline's `filter` gaps.
struct BlurredPart: Equatable, Codable, Sendable {

    /// A stretch of the session with no picture, because the frames there could not be blurred.
    struct Span: Equatable, Codable, Sendable {
        let from: SessionTime
        let to: SessionTime

        init(from: SessionTime, to: SessionTime) {
            self.from = from
            self.to = to
        }
    }

    /// What a pass says about one part when it has finished, in the part's own time: seconds from
    /// the first sample of its video.
    struct Report: Equatable, Sendable {
        /// Frames dropped one after another: from where the first of them was to be shown to
        /// where the next written frame is shown — or to the end of the video, when none follows.
        struct Run: Equatable, Sendable {
            let from: TimeInterval
            let to: TimeInterval

            init(from: TimeInterval, to: TimeInterval) {
                self.from = from
                self.to = to
            }
        }

        /// Frames that went through the blur and were written.
        let framesWritten: Int64
        /// Frames the blur could not process. None of them is in the blurred part.
        let framesDropped: Int64
        let droppedRuns: [Run]
        /// Whether the blurred part carries the recorded part's sound.
        let keptSound: Bool

        init(framesWritten: Int64, framesDropped: Int64, droppedRuns: [Run] = [], keptSound: Bool) {
            self.framesWritten = framesWritten
            self.framesDropped = framesDropped
            self.droppedRuns = droppedRuns
            self.keptSound = keptSound
        }

        var keptPictures: Bool { framesWritten > 0 }
        /// Every picture was dropped and there was no sound: there is no part left to keep.
        var keptNothing: Bool { !keptPictures && !keptSound }
    }

    let partID: String
    let framesWritten: Int64
    let framesDropped: Int64
    /// The stretches worth writing down as gaps, on the session's clock, in time order.
    let gaps: [Span]

    init(partID: String, framesWritten: Int64, framesDropped: Int64, gaps: [Span] = []) {
        self.partID = partID
        self.framesWritten = framesWritten
        self.framesDropped = framesDropped
        self.gaps = gaps
    }

    /// A run of dropped frames shorter than this is counted and not written as a gap: the picture
    /// before it is simply held a little longer. A gap is something the office's rules treat as
    /// "no video here", and one lost frame should not cut a twenty-second action in two.
    static let gapThreshold = SessionTime(milliseconds: 1_000)

    /// A pass's report placed on the session's clock.
    ///
    /// - Parameter video: where the recorded part's video lay before it was blurred, or nil when
    ///   the recording's journal has none for it. With no pictures written, the whole of it is one
    ///   gap however short; otherwise each run of the threshold's length or more is a gap, held
    ///   inside the part.
    init(partID: String, report: Report, video: SessionTimeline.Part?) {
        var spans: [Span] = []
        if let video, video.tZero < video.end {
            if !report.keptPictures {
                spans = [Span(from: video.tZero, to: video.end)]
            } else {
                for run in report.droppedRuns where run.from.isFinite && run.to.isFinite {
                    let from = max(video.tZero, min(video.end, video.tZero + SessionTime(seconds: run.from)))
                    let to = max(video.tZero, min(video.end, video.tZero + SessionTime(seconds: run.to)))
                    guard to - from >= Self.gapThreshold else { continue }
                    spans.append(Span(from: from, to: to))
                }
            }
        }
        self.init(partID: partID, framesWritten: report.framesWritten, framesDropped: report.framesDropped,
                  gaps: spans.sorted { ($0.from, $0.to) < ($1.from, $1.to) })
    }

    /// Every frame dropped across a recording's parts: the manifest's `droppedFrames`.
    static func droppedFrames(_ parts: [BlurredPart]) -> Int64 {
        parts.reduce(0) { $0 + max(0, $1.framesDropped) }
    }

    /// The timeline's gaps for a blurred recording: the gaps between its parts, and a `filter`
    /// gap on the video for each stretch the blur left without a picture.
    ///
    /// A stretch can lie inside a gap between two parts — a part none of whose pictures could be
    /// blurred has no video left, so the parts either side of it are now neighbours. The stretch
    /// is then cut out of that gap, so no moment of the video has two reasons.
    static func timelineGaps(between parts: [SessionTimeline.Gap], blurred: [BlurredPart]) -> [SessionTimeline.Gap] {
        let filtered = blurred.flatMap(\.gaps).filter { $0.from < $0.to }
        guard !filtered.isEmpty else { return parts }
        var gaps: [SessionTimeline.Gap] = []
        for gap in parts {
            guard gap.track == .video else {
                gaps.append(gap)
                continue
            }
            var pieces = [(from: gap.from, to: gap.to)]
            for cut in filtered {
                pieces = pieces.flatMap { piece -> [(from: SessionTime, to: SessionTime)] in
                    guard cut.from < piece.to, cut.to > piece.from else { return [piece] }
                    var kept: [(from: SessionTime, to: SessionTime)] = []
                    if piece.from < cut.from { kept.append((piece.from, cut.from)) }
                    if cut.to < piece.to { kept.append((cut.to, piece.to)) }
                    return kept
                }
            }
            gaps += pieces.map { SessionTimeline.Gap(track: .video, from: $0.from, to: $0.to, reason: gap.reason) }
        }
        gaps += filtered.map { SessionTimeline.Gap(track: .video, from: $0.from, to: $0.to, reason: .filter) }
        return gaps
    }
}
