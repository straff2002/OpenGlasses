import Foundation

/// A caption entry carrying a monotonically increasing sequence number.
protocol CaptionSequenced {
    var seq: UInt64 { get }
}

/// Tracks which caption entries a consumer has already read.
///
/// `AmbientCaptionService.captionHistory` is a bounded newest-first buffer (`maxHistory`), so
/// consumers cannot track their position by array count: once the buffer is full its count
/// stops growing and a count-based cursor concludes "nothing new" forever — recording
/// transcripts and the live meeting summary both went silent after `maxHistory` captions.
/// Sequence numbers survive eviction.
struct CaptionCursor {
    private(set) var lastSeq: UInt64 = 0

    /// Returns the entries not yet seen, oldest → newest.
    /// - Parameter history: caption history ordered newest → oldest.
    mutating func take<T: CaptionSequenced>(newestFirst history: [T]) -> [T] {
        // History is descending by `seq`, so every unseen entry is at the front.
        let fresh = history.prefix { $0.seq > lastSeq }
        guard let newest = fresh.first else { return [] }
        lastSeq = newest.seq
        return Array(fresh.reversed())
    }
}
