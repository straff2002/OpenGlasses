import Foundation

/// Every final caption of the current captions session, oldest first, so a meeting summary can
/// cover the whole meeting rather than the few minutes `AmbientCaptionService.captionHistory`
/// (capped at 50 for the screen) still holds.
///
/// **Memory only, exactly like `captionHistory`.** Nothing here is written to disk, logged or
/// kept past the process. It starts empty when captions start and is still there after they stop,
/// because the summary is usually asked for afterwards. A caption reaches it only through
/// `AmbientCaptionService.finalizeCaption` (after `TranscriptGuard`) or `insertVisualNote`, the
/// same two doors `captionHistory` has.
///
/// Bounded at `CaptionSessionRecorder.turnCap` lines, about eight hours: past that the oldest line
/// goes and `dropped` counts it, so the summary can say plainly that the start is no longer held.
struct MeetingTranscriptBuffer: Equatable, Sendable {

    /// One final caption: what a `CaptionEntry` carries, minus its screen-only identity.
    struct Line: Equatable, Sendable {
        let text: String
        let timestamp: Date
        /// Diarized speaker id, nil on the unlabeled path.
        var speaker: Int? = nil
        /// Source-language words when `text` is a translation.
        var original: String? = nil
        /// Detected source language of a translated caption.
        var language: String? = nil
    }

    static let defaultCapacity = CaptionSessionRecorder.turnCap

    let capacity: Int
    /// Oldest first.
    private(set) var lines: [Line] = []
    /// How many of the oldest lines went to keep within `capacity`.
    private(set) var dropped = 0

    init(capacity: Int = MeetingTranscriptBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var isEmpty: Bool { lines.isEmpty }
    var count: Int { lines.count }

    mutating func append(_ line: Line) {
        let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(Line(text: trimmed, timestamp: line.timestamp, speaker: line.speaker,
                          original: line.original, language: line.language))
        if lines.count > capacity {
            let removing = lines.count - capacity
            lines.removeFirst(removing)
            dropped += removing
        }
    }

    mutating func removeAll() {
        lines.removeAll()
        dropped = 0
    }
}
