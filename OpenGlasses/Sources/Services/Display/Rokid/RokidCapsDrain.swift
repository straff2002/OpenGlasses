import Foundation

/// Splits what an MFi session reads into whole Caps blobs.
///
/// On an `EASession` iOS owns the iAP2 link layer in both directions (see ``RokidMFIFraming``), so
/// a read carries bare blobs: no `FF 5A` sync, no timestamp or session id, no checksum. The only
/// boundary is the blob's own header, `u32 BE total` (the whole blob, these four bytes included)
/// followed by the version byte `0x05`. A blob can still arrive split across reads, or several in
/// one, because the session is a byte stream.
///
/// With no sync word there is nothing to rescan for. A header that cannot start a blob (the wrong
/// version byte, or a total outside ``minimumBlobLength``…``maximumBlobLength``) means the stream
/// has lost its place, so everything buffered is dropped and counted in ``discardedByteCount``,
/// and the next read starts afresh. Losing a few bytes is recoverable. Guessing a boundary would
/// misread every blob after it.
struct RokidCapsDrain {

    /// The smallest blob: the four-byte total, the version byte and a zero member count.
    static let minimumBlobLength = 6

    /// The glasses send each blob inside one link frame, whose length field is 16 bits and which
    /// spends ``RokidMFIPayload/envelopeOverhead`` bytes on itself. A total past this is not a
    /// header.
    static let maximumBlobLength = Int(UInt16.max) - RokidMFIPayload.envelopeOverhead

    /// Bytes before the total can be read and checked: the total itself plus the version byte.
    static let headerLength = 5

    private var pending: [UInt8] = []

    /// Bytes held back because they may be the start of a blob that has not fully arrived.
    var pendingByteCount: Int { pending.count }

    /// Bytes thrown away because they could not start a blob. Non-zero means the stream lost its
    /// place at least once, which is worth showing in a probe.
    private(set) var discardedByteCount = 0

    init() {}

    /// Feed one read and return every blob that completed because of it, in order.
    mutating func append(_ chunk: [UInt8]) -> [[UInt8]] {
        guard !chunk.isEmpty else { return [] }
        pending.append(contentsOf: chunk)

        var blobs: [[UInt8]] = []
        var start = 0
        while pending.count - start >= Self.headerLength {
            guard let total = Self.declaredLength(of: pending, at: start) else {
                discardedByteCount += pending.count - start
                start = pending.count
                break
            }
            guard pending.count - start >= total else { break }
            blobs.append(Array(pending[start..<(start + total)]))
            start += total
        }
        if start > 0 { pending.removeFirst(start) }
        return blobs
    }

    /// Drop buffered bytes. Call on disconnect so a partial blob from one session cannot run into
    /// the first blob of the next.
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    /// The total a blob header at `offset` declares, or `nil` when those bytes cannot start a blob.
    static func declaredLength(of bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, bytes.count - offset >= headerLength else { return nil }
        let total = Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
        guard bytes[offset + 4] == RokidCapsCodec.version,
              total >= minimumBlobLength,
              total <= maximumBlobLength else { return nil }
        return total
    }

    /// Whether `bytes` is exactly one well-formed blob: a valid header whose total is the whole
    /// array, and members that decode to the last byte.
    static func isBlob(_ bytes: [UInt8]) -> Bool {
        guard declaredLength(of: bytes, at: 0) == bytes.count else { return false }
        var offset = 0
        guard (try? RokidCapsCodec.decode(bytes, offset: &offset)) != nil else { return false }
        return offset == bytes.count
    }
}
