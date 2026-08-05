import XCTest
@testable import OpenGlasses

/// `AmbientCaptionService.captionHistory` is a *bounded* newest-first buffer (`maxHistory`).
/// Consumers used to track their position with a plain count, which freezes permanently once
/// the buffer stops growing — the live meeting summary and the saved transcript both went
/// silent after `maxHistory` finalized captions. `CaptionCursor` tracks sequence numbers, which
/// survive eviction.
final class CaptionCursorTests: XCTestCase {

    private struct Entry: CaptionSequenced, Equatable {
        let seq: UInt64
        let text: String
    }

    /// Newest-first, matching `captionHistory` ordering.
    private func history(_ seqs: [UInt64]) -> [Entry] {
        seqs.sorted(by: >).map { Entry(seq: $0, text: "c\($0)") }
    }

    func testEmptyHistoryYieldsNothing() {
        var cursor = CaptionCursor()
        XCTAssertTrue(cursor.take(newestFirst: [Entry]()).isEmpty)
    }

    func testFirstTakeReturnsEverythingOldestFirst() {
        var cursor = CaptionCursor()
        let taken = cursor.take(newestFirst: history([1, 2, 3]))
        XCTAssertEqual(taken.map(\.seq), [1, 2, 3])
    }

    func testSecondTakeOnUnchangedHistoryReturnsNothing() {
        var cursor = CaptionCursor()
        let buffer = history([1, 2, 3])
        _ = cursor.take(newestFirst: buffer)
        XCTAssertTrue(cursor.take(newestFirst: buffer).isEmpty)
    }

    func testTakeReturnsOnlyEntriesAddedSinceLastTake() {
        var cursor = CaptionCursor()
        _ = cursor.take(newestFirst: history([1, 2, 3]))
        let taken = cursor.take(newestFirst: history([1, 2, 3, 4, 5]))
        XCTAssertEqual(taken.map(\.seq), [4, 5])
    }

    /// The regression that motivated this type: once the ring buffer is full its `count` stops
    /// growing, so a count-based cursor concluded "nothing new" forever.
    func testKeepsDeliveringAfterBufferStartsEvicting() {
        let cap = 4
        var cursor = CaptionCursor()
        var buffer = history([1, 2, 3, 4])
        XCTAssertEqual(cursor.take(newestFirst: buffer).map(\.seq), [1, 2, 3, 4])

        // Two more captions arrive; the buffer is at cap, so 1 and 2 are evicted and
        // `buffer.count` stays at 4 — exactly the condition that froze the old cursor.
        buffer = Array(history([3, 4, 5, 6]).prefix(cap))
        XCTAssertEqual(buffer.count, cap)

        XCTAssertEqual(cursor.take(newestFirst: buffer).map(\.seq), [5, 6])
    }

    /// A consumer that falls far enough behind loses the evicted captions, but must resync to
    /// what is still in the buffer rather than stall or replay.
    func testResyncsWhenEverythingInBufferIsNew() {
        var cursor = CaptionCursor()
        _ = cursor.take(newestFirst: history([1, 2]))
        let taken = cursor.take(newestFirst: history([7, 8, 9]))
        XCTAssertEqual(taken.map(\.seq), [7, 8, 9])
    }

    /// A fresh cursor seeded against a populated buffer starts from the present — that is how a
    /// new recording avoids inheriting the previous conversation's captions.
    func testFreshCursorSeededOnExistingBufferSkipsTheBacklog() {
        var cursor = CaptionCursor()
        let backlog = history([1, 2, 3])
        _ = cursor.take(newestFirst: backlog)
        XCTAssertEqual(cursor.take(newestFirst: history([1, 2, 3, 4])).map(\.seq), [4])
    }
}

/// Companion fix from the same review: a recording stopped and restarted within one second used
/// to collide on the timestamp-only audio file name.
@MainActor
final class AudioRecordingFileNameTests: XCTestCase {
    func testRecordingFileNamesRemainUniqueWithinTheSameSecond() {
        let now = Date(timeIntervalSince1970: 1_000)

        let first = AudioRecordingService.recordingFileName(now: now, id: UUID())
        let second = AudioRecordingService.recordingFileName(now: now, id: UUID())

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".m4a"))
        XCTAssertTrue(second.hasSuffix(".m4a"))
    }
}
