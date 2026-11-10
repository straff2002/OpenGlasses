import XCTest
@testable import OpenGlasses

/// Instant Replay P0 — the pure index over the buffer's segments: capacity, eviction, and the
/// span a save takes across segment boundaries.
final class ReplaySegmentRingTests: XCTestCase {

    /// A 2-second segment starting at `start`, frames at 15 fps.
    private func segment(_ index: Int, start: TimeInterval, length: TimeInterval = 2 - 1.0 / 15,
                         width: Int = 720, dropped: Bool = false, filter: Bool = true) -> ReplaySegment {
        ReplaySegment(fileName: "segment-\(index).mp4", firstFrameAt: start,
                      lastFrameAt: start + length, frameCount: 30, width: width, height: 1280,
                      hadDroppedFrames: dropped, filterWasOn: filter)
    }

    /// `count` back-to-back segments from t = 100.
    private func ring(_ count: Int, capacity: Int = 31) -> ReplaySegmentRing {
        var ring = ReplaySegmentRing(capacity: capacity)
        for i in 0..<count { ring.append(segment(i, start: 100 + Double(i) * 2)) }
        return ring
    }

    // MARK: - Append, rotate, drop oldest

    func testAppendKeepsOrderUntilFull() {
        var ring = ReplaySegmentRing(capacity: 3)
        XCTAssertEqual(ring.append(segment(0, start: 0)), [])
        XCTAssertEqual(ring.append(segment(1, start: 2)), [])
        XCTAssertEqual(ring.append(segment(2, start: 4)), [])
        XCTAssertEqual(ring.segments.map(\.fileName), ["segment-0.mp4", "segment-1.mp4", "segment-2.mp4"])
    }

    func testTheOldestIsEvictedAndHandedBackForDeletion() {
        var ring = ReplaySegmentRing(capacity: 3)
        for i in 0..<3 { ring.append(segment(i, start: Double(i) * 2)) }
        let evicted = ring.append(segment(3, start: 6))
        XCTAssertEqual(evicted.map(\.fileName), ["segment-0.mp4"])
        XCTAssertEqual(ring.count, 3)
        XCTAssertEqual(ring.segments.first?.fileName, "segment-1.mp4")
    }

    func testAMinuteBufferNeverHoldsMoreThanItsCapacity() {
        let capacity = ReplayBufferPlan(bufferSeconds: 60, width: 2, height: 2, frameRate: 15).capacity
        var ring = ReplaySegmentRing(capacity: capacity)
        var evictedTotal = 0
        for i in 0..<100 { evictedTotal += ring.append(segment(i, start: Double(i) * 2)).count }
        XCTAssertEqual(ring.count, capacity)
        XCTAssertEqual(evictedTotal, 100 - capacity)
        XCTAssertGreaterThanOrEqual(ring.continuousSeconds, 60, "the full minute is always on disk")
    }

    func testASegmentOlderThanTheNewestIsRefused() {
        var ring = ReplaySegmentRing(capacity: 5)
        ring.append(segment(0, start: 10))
        let refused = ring.append(segment(1, start: 5))
        XCTAssertEqual(refused.map(\.fileName), ["segment-1.mp4"])
        XCTAssertEqual(ring.count, 1)
    }

    func testRemoveAllHandsBackEverything() {
        var ring = ring(4)
        XCTAssertEqual(ring.removeAll().count, 4)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertEqual(ring.continuousSeconds, 0)
    }

    // MARK: - The save window across segment boundaries

    func testThirtySecondsCoversThirtyToThirtyTwoAndEndsOnTheNewestFrame() throws {
        let ring = ring(31)   // t = 100 … 162
        let now = ring.segments.last!.lastFrameAt
        let span = try XCTUnwrap(ring.span(coveringLast: 30, now: now))
        XCTAssertEqual(span.segments.last, ring.segments.last)
        XCTAssertGreaterThanOrEqual(span.coveredSeconds, 30 - 0.1)
        XCTAssertLessThanOrEqual(span.coveredSeconds, 32)
        XCTAssertEqual(span.segments.count, 16)
        XCTAssertFalse(span.stoppedAtGap)
        // Oldest first.
        XCTAssertEqual(span.segments.map(\.firstFrameAt), span.segments.map(\.firstFrameAt).sorted())
    }

    func testAskingForMoreThanIsHeldTakesEverything() throws {
        let ring = ring(10)   // 20 s
        let now = ring.segments.last!.lastFrameAt
        let span = try XCTUnwrap(ring.span(coveringLast: 60, now: now))
        XCTAssertEqual(span.segments.count, 10)
        XCTAssertLessThan(span.coveredSeconds, 21)
        XCTAssertFalse(span.stoppedAtGap)
    }

    func testAGapLongerThanASegmentIsABoundary() throws {
        var ring = ReplaySegmentRing(capacity: 31)
        for i in 0..<5 { ring.append(segment(i, start: 100 + Double(i) * 2)) }           // 100 … 110
        for i in 5..<10 { ring.append(segment(i, start: 120 + Double(i - 5) * 2)) }      // stall, 120 … 130
        let span = try XCTUnwrap(ring.span(coveringLast: 60, now: 130))
        XCTAssertEqual(span.segments.map(\.fileName).first, "segment-5.mp4", "stops at the stall")
        XCTAssertTrue(span.stoppedAtGap)
        XCTAssertLessThan(span.coveredSeconds, 11)
        XCTAssertLessThan(ring.continuousSeconds, 11)
    }

    func testAGapNoLongerThanASegmentIsNotABoundary() throws {
        var ring = ReplaySegmentRing(capacity: 31)
        ring.append(segment(0, start: 100))
        ring.append(segment(1, start: 103.5))   // 1.57 s after the last frame of the first
        let span = try XCTUnwrap(ring.span(coveringLast: 10, now: 105.5))
        XCTAssertEqual(span.segments.count, 2)
        XCTAssertFalse(span.stoppedAtGap)
    }

    func testASizeChangeIsABoundary() throws {
        var ring = ReplaySegmentRing(capacity: 31)
        ring.append(segment(0, start: 100, width: 720))
        ring.append(segment(1, start: 102, width: 504))
        let span = try XCTUnwrap(ring.span(coveringLast: 10, now: 104))
        XCTAssertEqual(span.segments.map(\.width), [504])
        XCTAssertTrue(span.stoppedAtGap)
    }

    func testAStreamThatStalledAtThePresentGivesOnlyWhatIsInsideTheWindow() throws {
        let ring = ring(10)   // ends ≈ 120
        // Asked at 140 for the last 30 s: only what falls after 110.
        let span = try XCTUnwrap(ring.span(coveringLast: 30, now: 140))
        XCTAssertTrue(span.segments.allSatisfy { $0.lastFrameAt > 110 })
        XCTAssertLessThan(span.coveredSeconds, 12)
        // Asked at 200: nothing in the window at all.
        XCTAssertNil(ring.span(coveringLast: 30, now: 200))
    }

    func testAnEmptyRingHasNoSpan() {
        XCTAssertNil(ReplaySegmentRing(capacity: 4).span(coveringLast: 30, now: 10))
    }

    func testTheSpanCarriesDroppedFramesAndTheBlurAcrossItsSegments() throws {
        var ring = ReplaySegmentRing(capacity: 31)
        ring.append(segment(0, start: 100, dropped: true, filter: true))
        ring.append(segment(1, start: 102, dropped: false, filter: false))
        let span = try XCTUnwrap(ring.span(coveringLast: 10, now: 104))
        XCTAssertTrue(span.includesDroppedFrames)
        XCTAssertFalse(span.filterWasOn, "one unblurred segment makes the clip not blurred throughout")
        let onlyNewest = try XCTUnwrap(ring.span(coveringLast: 1, now: 104))
        XCTAssertEqual(onlyNewest.segments.count, 1)
        XCTAssertFalse(onlyNewest.includesDroppedFrames)
    }

    func testASegmentsDurationIncludesItsLastFrame() {
        let one = ReplaySegment(fileName: "a", firstFrameAt: 5, lastFrameAt: 5, frameCount: 1,
                                width: 2, height: 2, hadDroppedFrames: false, filterWasOn: true)
        XCTAssertEqual(one.duration(frameRate: 15), 1.0 / 15, accuracy: 1e-9)
        XCTAssertEqual(segment(0, start: 0).duration(frameRate: 15), 2, accuracy: 1e-9)
    }
}
