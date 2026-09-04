import Foundation

/// Turning a stream of token *bytes* into a stream of correct Swift strings, and stopping it on the
/// caller's stop sequences.
///
/// Both problems are the same shape and both are boundary problems, which is why they are pure
/// value types tested directly rather than logic buried in the generation loop.

/// Accumulates token bytes and emits only whole UTF-8 scalars (Plan DZ generation step 8).
///
/// A byte-pair-encoding vocabulary happily splits a multi-byte character across two tokens: an
/// emoji arrives as four tokens of one byte each, and a naive `String(decoding:)` per token turns
/// each of them into `U+FFFD`. So bytes are held until the sequence they belong to is complete.
/// Nothing is ever dropped: a byte that is genuinely invalid — not merely incomplete — is emitted
/// through UTF-8's own replacement behaviour rather than accumulated forever.
struct LlamaUTF8Accumulator {

    /// Bytes belonging to a sequence that has not finished arriving. Never longer than 3.
    private var pending: [UInt8] = []

    init() {}

    /// True while bytes are held back waiting for the rest of their sequence.
    var hasPendingBytes: Bool { !pending.isEmpty }

    /// Append token bytes and return whatever is now complete. May legitimately return `""`.
    mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        pending.append(contentsOf: bytes)
        let boundary = Self.completeBoundary(in: pending)
        guard boundary > 0 else { return "" }
        let complete = pending[..<boundary]
        pending.removeFirst(boundary)
        return String(decoding: complete, as: UTF8.self)
    }

    /// Emit anything still held. Called once at the end of a generation so a truncated final
    /// sequence surfaces as a replacement character instead of vanishing.
    mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let remainder = pending
        pending.removeAll()
        return String(decoding: remainder, as: UTF8.self)
    }

    /// Index one past the last byte that can be decoded now.
    ///
    /// Scans back from the end for the lead byte of the final sequence. If that sequence is short
    /// of its declared length, the boundary is its start; otherwise everything is complete. More
    /// than three trailing continuation bytes with no lead byte is malformed input, not an
    /// incomplete sequence, so it is released rather than held.
    static func completeBoundary(in bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let maxLookback = min(4, bytes.count)
        for step in 1...maxLookback {
            let index = bytes.count - step
            let byte = bytes[index]
            if byte < 0x80 { return bytes.count }           // ASCII: nothing outstanding
            if byte < 0xC0 { continue }                      // continuation: keep scanning back
            let expected = sequenceLength(leadByte: byte)
            // An invalid lead byte (0xF8…0xFF) declares no length; releasing it lets UTF-8's own
            // replacement handle it instead of stalling the stream on a byte that never completes.
            guard expected > 0 else { return bytes.count }
            return step < expected ? index : bytes.count
        }
        return bytes.count
    }

    /// Total byte length a UTF-8 sequence with this lead byte occupies, or `0` when it is not a
    /// valid lead byte.
    static func sequenceLength(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return 0
        }
    }
}

/// Holds back just enough text to recognise a stop sequence that straddles token boundaries.
///
/// A stop sequence rarely arrives as one token: `</tool>` can come as `<`, `/`, `too`, `l>`. If the
/// loop emitted each piece as it arrived, the wearer would see the start of the marker before the
/// match completed. So the matcher keeps a suffix of `longestStop - 1` characters back, which is
/// the most that can turn out to belong to a stop sequence.
struct LlamaStopSequenceMatcher {

    private let stopSequences: [String]
    private let holdBack: Int
    private var buffer = ""
    private var stopped = false

    init(stopSequences: [String]) {
        // Empty stops would match everywhere; they are a caller mistake, not a request to stop
        // immediately.
        let usable = stopSequences.filter { !$0.isEmpty }
        self.stopSequences = usable
        self.holdBack = max(0, (usable.map(\.count).max() ?? 0) - 1)
    }

    /// True once a stop sequence has matched. No further text is emitted.
    var hasStopped: Bool { stopped }

    /// Feed newly decoded text. Returns the text safe to emit now, and whether generation should
    /// stop. Text at and after the stop sequence is never emitted.
    mutating func consume(_ text: String) -> (emit: String, stop: Bool) {
        guard !stopped else { return ("", true) }
        guard !stopSequences.isEmpty else { return (text, false) }
        buffer += text

        if let match = earliestMatch() {
            stopped = true
            let emit = String(buffer[buffer.startIndex..<match])
            buffer = ""
            return (emit, true)
        }
        guard buffer.count > holdBack else { return ("", false) }
        let emitCount = buffer.count - holdBack
        let splitIndex = buffer.index(buffer.startIndex, offsetBy: emitCount)
        let emit = String(buffer[buffer.startIndex..<splitIndex])
        buffer = String(buffer[splitIndex...])
        return (emit, false)
    }

    /// Release the held-back tail. Called when generation ends for any reason other than a match.
    mutating func flush() -> String {
        guard !stopped else { return "" }
        let remainder = buffer
        buffer = ""
        return remainder
    }

    /// Start index of the earliest stop sequence in the buffer, if any.
    private func earliestMatch() -> String.Index? {
        var earliest: String.Index?
        for stop in stopSequences {
            guard let range = buffer.range(of: stop) else { continue }
            if earliest == nil || range.lowerBound < earliest! { earliest = range.lowerBound }
        }
        return earliest
    }
}
