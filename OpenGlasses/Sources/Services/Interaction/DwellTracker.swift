import Foundation
import CoreGraphics

/// Pure "hold your gaze on a thing to trigger" state machine (Plan CG P1).
///
/// Consumes timestamped candidate boxes (normalized 0–1, any coordinate convention —
/// the tracker only compares boxes with each other) and fires when one object stays
/// in the central gaze region for `dwellSeconds`. Head-center dwell stands in for gaze:
/// the glasses point where the head points. No Vision/SDK imports — callers supply
/// boxes from whatever detector they like; tests supply synthetic sequences.
struct DwellTracker {
    struct Config {
        /// Continuous seconds an object must hold the center before firing.
        var dwellSeconds: TimeInterval = 2.0
        /// Minimum IoU for two boxes to count as the same object across frames.
        var iouThreshold: CGFloat = 0.4
        /// Central region (normalized) a candidate's center must fall inside.
        var centerRegion = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        /// After firing, ignore everything for this long so one stare can't repeat-fire.
        var cooldownSeconds: TimeInterval = 4.0
        /// Detector flicker tolerance: a lost candidate keeps its clock this long.
        var graceSeconds: TimeInterval = 0.5

        init() {}
    }

    enum Event: Equatable {
        case idle
        /// An object is being tracked; progress ∈ [0, 1) toward firing.
        case tracking(progress: Double)
        /// Dwell complete — `box` is the last observed box of the tracked object.
        case fired(box: CGRect)
        case coolingDown
    }

    let config: Config

    private var trackedBox: CGRect?
    private var trackStart: TimeInterval = 0
    private var lastSeen: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed one frame's detection boxes; returns the tracker's event for this frame.
    mutating func process(boxes: [CGRect], at time: TimeInterval) -> Event {
        if time < cooldownUntil { return .coolingDown }

        guard let candidate = centeredCandidate(in: boxes) else {
            // Nothing in the center: hold through brief detector flicker, else reset.
            if let _ = trackedBox, time - lastSeen <= config.graceSeconds {
                return .tracking(progress: progress(at: lastSeen))
            }
            trackedBox = nil
            return .idle
        }

        if let tracked = trackedBox, iou(tracked, candidate) >= config.iouThreshold {
            trackedBox = candidate  // follow slow drift
            lastSeen = time
            if time - trackStart >= config.dwellSeconds {
                trackedBox = nil
                cooldownUntil = time + config.cooldownSeconds
                return .fired(box: candidate)
            }
            return .tracking(progress: progress(at: time))
        }

        // New (or replaced) object: the clock starts over.
        trackedBox = candidate
        trackStart = time
        lastSeen = time
        return .tracking(progress: 0)
    }

    /// Drop any in-progress track (e.g. the feature was toggled off mid-stare).
    mutating func reset() {
        trackedBox = nil
        cooldownUntil = 0
    }

    // MARK: - Internals

    private func progress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - trackStart) / config.dwellSeconds))
    }

    /// Largest box whose center falls inside the center region.
    private func centeredCandidate(in boxes: [CGRect]) -> CGRect? {
        boxes
            .filter { config.centerRegion.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
