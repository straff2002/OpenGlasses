import Foundation

/// One finished segment of the Instant Replay buffer: a short MP4 that starts on a keyframe.
///
/// Times are seconds on the host clock the buffer stamps frames with — the moment each frame
/// arrived off the privacy relay. (Whether the glasses deliver frames evenly enough for arrival
/// time to be honest is what `FrameCadenceAnalyzer` measures.)
struct ReplaySegment: Equatable {
    /// The file's name inside the buffer directory. Never a path.
    let fileName: String
    let firstFrameAt: TimeInterval
    let lastFrameAt: TimeInterval
    let frameCount: Int
    /// The pixel size the segment was encoded at. A size change is a boundary: segments of two
    /// sizes cannot be joined without a re-encode.
    let width: Int
    let height: Int
    /// The relay dropped frames while this segment was being written (coalescing, or the blur
    /// refusing a frame it could not process).
    let hadDroppedFrames: Bool
    /// The bystander blur was on for the whole of this segment.
    let filterWasOn: Bool

    /// How much picture the segment holds: first frame to last, plus one frame's worth so a
    /// one-frame segment is not zero long.
    func duration(frameRate: Int) -> TimeInterval {
        max(0, lastFrameAt - firstFrameAt) + 1 / Double(max(1, frameRate))
    }
}

/// The run of segments a save will use, oldest first, and what it actually covers.
struct ReplaySpan: Equatable {
    let segments: [ReplaySegment]
    /// From the first frame of the oldest segment to the last frame of the newest.
    let coveredSeconds: TimeInterval
    /// The run stopped at a gap or a size change before reaching as far back as was asked.
    let stoppedAtGap: Bool
    let includesDroppedFrames: Bool
    /// The blur was on for every segment in the run.
    let filterWasOn: Bool
}

/// The pure index over the buffer's segment files (Instant Replay §4).
///
/// Fixed capacity with oldest-first eviction, and no I/O: the service owns the files and deletes
/// what `append` hands back. Time is always passed in.
struct ReplaySegmentRing: Equatable {

    let capacity: Int
    /// Two consecutive segments further apart than this are not one continuous piece of video.
    /// One segment's length: a stall or a run of refused frames longer than that is a gap.
    let gapTolerance: TimeInterval
    private(set) var segments: [ReplaySegment] = []

    init(capacity: Int, gapTolerance: TimeInterval = ReplayBufferPlan.segmentSeconds) {
        self.capacity = max(1, capacity)
        self.gapTolerance = gapTolerance
    }

    var isEmpty: Bool { segments.isEmpty }
    var count: Int { segments.count }

    /// Add the newest segment. Returns the segments evicted to stay within capacity, oldest first,
    /// for the caller to delete. A segment that arrives out of order (older than the newest held)
    /// is refused and returned as evicted: the ring is time-ordered by construction.
    @discardableResult
    mutating func append(_ segment: ReplaySegment) -> [ReplaySegment] {
        if let newest = segments.last, segment.firstFrameAt < newest.lastFrameAt {
            return [segment]
        }
        segments.append(segment)
        guard segments.count > capacity else { return [] }
        let overflow = segments.count - capacity
        let evicted = Array(segments.prefix(overflow))
        segments.removeFirst(overflow)
        return evicted
    }

    /// Forget everything. Returns what was held, for the caller to delete.
    @discardableResult
    mutating func removeAll() -> [ReplaySegment] {
        let all = segments
        segments = []
        return all
    }

    /// Whether `older` and `newer` are one continuous piece of video.
    func isContinuous(_ older: ReplaySegment, _ newer: ReplaySegment) -> Bool {
        newer.firstFrameAt - older.lastFrameAt <= gapTolerance
            && older.width == newer.width && older.height == newer.height
    }

    /// The newest contiguous run of segments covering the last `seconds` before `now`, oldest
    /// first; nil when nothing in the buffer falls inside that window.
    ///
    /// Walks back from the newest segment. It stops at the first segment that ends before the
    /// window opens, at a gap (a stall, or the relay refusing frames for longer than a segment),
    /// at a change of size, or once the run reaches back to the start of the window. Because the
    /// cut lands on a segment's keyframe, a 30-second ask normally covers 30–32 seconds.
    func span(coveringLast seconds: TimeInterval, now: TimeInterval) -> ReplaySpan? {
        let windowStart = now - max(0, seconds)
        var picked: [ReplaySegment] = []
        var stoppedAtGap = false
        for segment in segments.reversed() {
            // Strictly before: a segment whose last frame falls on the window's first instant
            // still holds a frame of it, and leaving it out would cut a 30-second ask short.
            if segment.lastFrameAt < windowStart { break }
            if let newerNeighbour = picked.last, !isContinuous(segment, newerNeighbour) {
                stoppedAtGap = true
                break
            }
            picked.append(segment)
            if segment.firstFrameAt <= windowStart { break }
        }
        guard let newest = picked.first, let oldest = picked.last else { return nil }
        let run = Array(picked.reversed())
        return ReplaySpan(segments: run,
                          coveredSeconds: max(0, newest.lastFrameAt - oldest.firstFrameAt),
                          stoppedAtGap: stoppedAtGap,
                          includesDroppedFrames: run.contains { $0.hadDroppedFrames },
                          filterWasOn: run.allSatisfy(\.filterWasOn))
    }

    /// Seconds of continuous video ending at the newest segment — what the status line reports.
    var continuousSeconds: TimeInterval {
        guard let newest = segments.last else { return 0 }
        var oldest = newest
        for segment in segments.reversed().dropFirst() {
            guard isContinuous(segment, oldest) else { break }
            oldest = segment
        }
        return max(0, newest.lastFrameAt - oldest.firstFrameAt)
    }
}
