import Foundation

/// Keeps a realtime provider's audio aligned to whole frames across chunks (Plan LT §7).
///
/// A provider streams 16-bit PCM in base64 chunks, and nothing promises a chunk ends on a sample
/// boundary. Dividing each chunk's byte count by the frame size and dropping the remainder (what
/// `RealtimeAudioEngine` did) loses that byte *and* shifts every later sample of the reply by one
/// byte, which plays as loud noise. So the bytes past the last whole frame are held and put in
/// front of the next chunk. Pure, so the alignment is tested without an audio engine.
///
/// Clear it whenever the stream restarts — a new response, an interruption, a stop — so a held
/// byte from one reply is never glued onto the next.
struct PCMByteCarry: Equatable {
    /// Bytes per frame: bytes per sample × channels. 2 for 16-bit mono.
    let frameBytes: Int
    private(set) var held = Data()

    init(frameBytes: Int) {
        self.frameBytes = max(1, frameBytes)
    }

    /// The whole frames available once `chunk` follows what is held; the rest is held.
    mutating func aligned(_ chunk: Data) -> Data {
        var bytes = held
        bytes.append(chunk)
        let remainder = bytes.count % frameBytes
        if remainder == 0 {
            held = Data()
            return bytes
        }
        held = Data(bytes.suffix(remainder))
        return Data(bytes.prefix(bytes.count - remainder))
    }

    mutating func reset() {
        held = Data()
    }
}
