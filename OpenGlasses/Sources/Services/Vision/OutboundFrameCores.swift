import Foundation
import CoreGraphics

/// Plan CP — back-pressure for a blur pipeline running at camera rate.
///
/// At ~30 fps you must never queue. If a blur is still running when the next frame arrives and the
/// arrival is appended, the backlog grows without bound and the stream drifts further behind real
/// time with every frame. It fails silently: nothing errors, the picture just becomes the past.
///
/// So: at most one frame in flight, at most one pending, and a new arrival while busy *replaces*
/// the pending one. Intermediate frames are dropped deliberately, and the count is exposed so the
/// cost is measurable on device rather than invisible.
///
/// Generic over the frame type so the policy is testable without UIKit.
struct FrameCoalescer<Frame> {

    enum Submission {
        /// Nothing in flight — start on this frame now.
        case process(Frame)
        /// Busy. This frame is now the pending one; `dropped` earlier frames never ran.
        case madePending(dropped: Int)
    }

    private(set) var isProcessing = false
    private var pending: Frame?

    /// Total frames discarded because a newer one arrived first. Cumulative, for logging.
    private(set) var totalDropped = 0

    init() {}

    mutating func submit(_ frame: Frame) -> Submission {
        guard isProcessing else {
            isProcessing = true
            return .process(frame)
        }
        // Replacing a pending frame means that older frame is never processed.
        let dropped = pending == nil ? 0 : 1
        totalDropped += dropped
        pending = frame
        return .madePending(dropped: dropped)
    }

    /// Call when a blur completes. Returns the next frame to process, if one is waiting.
    mutating func finishedProcessing() -> Frame? {
        guard let next = pending else {
            isProcessing = false
            return nil
        }
        pending = nil
        // Stays `isProcessing` — the caller is about to start on `next`.
        return next
    }

    /// Drop everything and go idle (stream stopped, filter toggled off).
    mutating func reset() {
        isProcessing = false
        pending = nil
    }
}

/// Plan CP — decouples *detecting* faces from *blurring* them.
///
/// Detection is the expensive half (tens of milliseconds of Vision); compositing a blur over
/// known rectangles is cheap. Running detection on every frame at camera rate is neither necessary
/// nor achievable, so the relay detects on an interval and reuses the last rectangles in between.
///
/// # The residual, stated plainly
///
/// A face that newly enters frame is **unblurred until the next detection** — up to one interval.
/// Three things keep that small rather than eliminating it: a short interval, a motion margin that
/// expands each rectangle so a moving head stays covered between passes, and a grace period during
/// which rectangles survive a detection that misses them, so a face does not flash unblurred on a
/// single bad pass. This is a mitigation, not a fix, and the plan says so.
struct FaceRectCache {

    /// How often Vision runs. Shorter closes the residual and costs more CPU.
    let detectionInterval: TimeInterval
    /// How long rectangles stay usable after the detection that produced them. Longer than the
    /// interval on purpose: a single missed pass must not unblur a face that is still there.
    let grace: TimeInterval
    /// Fraction of each rectangle's size added on every side, covering motion between passes.
    let motionMargin: CGFloat

    private var rects: [CGRect] = []
    private var lastDetection: TimeInterval?

    init(detectionInterval: TimeInterval = 0.2,
         grace: TimeInterval = 0.6,
         motionMargin: CGFloat = 0.25) {
        self.detectionInterval = detectionInterval
        self.grace = grace
        self.motionMargin = motionMargin
    }

    /// Whether Vision should run for the frame at `now`.
    func shouldDetect(now: TimeInterval) -> Bool {
        guard let last = lastDetection else { return true }   // nothing known yet
        return now - last >= detectionInterval
    }

    /// Record a detection result (possibly empty — an empty result is information).
    mutating func record(_ detected: [CGRect], at now: TimeInterval) {
        rects = detected
        lastDetection = now
    }

    /// Rectangles to blur on the frame at `now`, expanded for motion and clamped to `frameSize`.
    /// Empty once the last detection ages past `grace`, so stale rectangles never blur forever.
    func blurRects(now: TimeInterval, frameSize: CGSize) -> [CGRect] {
        guard let last = lastDetection, now - last <= grace, !rects.isEmpty else { return [] }
        let bounds = CGRect(origin: .zero, size: frameSize)
        return rects.map { rect in
            rect.insetBy(dx: -rect.width * motionMargin, dy: -rect.height * motionMargin)
                .intersection(bounds)
        }
        .filter { !$0.isNull && !$0.isEmpty }
    }

    /// True when rectangles are being reused rather than freshly detected — for logging, so the
    /// residual window is observable in a device trace.
    func isReusing(now: TimeInterval) -> Bool {
        guard let last = lastDetection else { return false }
        return now - last > 0 && now - last <= grace
    }

    mutating func reset() {
        rects = []
        lastDetection = nil
    }
}
