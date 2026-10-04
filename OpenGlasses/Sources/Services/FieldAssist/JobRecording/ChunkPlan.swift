import CryptoKit
import Foundation

/// How one media part of a recorded job is cut into chunks for the office
/// (Contracts/recorded-session.md §3).
///
/// A part is sent as fixed-size chunks, each named by the SHA-256 of its bytes. Every chunk but the
/// last is exactly `chunkBytes` long, and the chunks joined in order are the part, whose own digest
/// is here too. A chunk that has been delivered is never sent twice, whatever the transport does
/// inside a file, and progress can be counted.
///
/// The plan is made from bytes it is handed; it reads and writes no file.
struct ChunkPlan: Equatable, Sendable {
    /// The proposed chunk size, 32 MiB. The contract leaves the size open until the phone's
    /// folder to the office exists.
    static let proposedChunkBytes: Int64 = 32 * 1024 * 1024
    /// The largest whole number the contract lets a manifest carry.
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    struct Chunk: Equatable, Sendable {
        /// Lower-case hex SHA-256 of the chunk's bytes.
        let sha256: String
        /// Where the chunk begins in the part.
        let offset: Int64
        let bytes: Int64

        /// The chunk's fixed place in the bundle. The name is the digest and nothing else chooses it.
        var path: String { ChunkPlan.path(sha256: sha256) }
    }

    let chunkBytes: Int64
    /// The part's length.
    let bytes: Int64
    /// Lower-case hex SHA-256 of the whole part.
    let sha256: String
    let chunks: [Chunk]

    static func path(sha256: String) -> String { "media/\(sha256).chunk" }

    /// The plan for a part already in memory. Nil for a part with no bytes or a chunk size that is
    /// not a positive whole number the contract can carry.
    static func plan(_ part: Data, chunkBytes: Int64 = proposedChunkBytes) -> ChunkPlan? {
        guard var builder = Builder(chunkBytes: chunkBytes) else { return nil }
        builder.append(part)
        return builder.finish()
    }

    /// Makes the plan as the part goes past, so a part of any size is planned without being held.
    struct Builder {
        private let chunkBytes: Int64
        private var whole = SHA256()
        private var current = SHA256()
        private var currentBytes: Int64 = 0
        private var total: Int64 = 0
        private var chunks: [Chunk] = []

        init?(chunkBytes: Int64) {
            guard chunkBytes > 0, chunkBytes <= ChunkPlan.maximumSafeInteger else { return nil }
            self.chunkBytes = chunkBytes
        }

        mutating func append(_ data: Data) {
            var rest = data[...]
            while !rest.isEmpty {
                let take = rest.prefix(Int(min(chunkBytes - currentBytes, Int64(rest.count))))
                whole.update(data: take)
                current.update(data: take)
                currentBytes += Int64(take.count)
                total += Int64(take.count)
                rest = rest.dropFirst(take.count)
                if currentBytes == chunkBytes { closeChunk() }
            }
        }

        /// The finished plan, or nil when nothing was appended: a part with no media is not a part.
        mutating func finish() -> ChunkPlan? {
            if currentBytes > 0 { closeChunk() }
            guard total > 0, total <= ChunkPlan.maximumSafeInteger else { return nil }
            return ChunkPlan(chunkBytes: chunkBytes, bytes: total, sha256: ChunkPlan.hex(whole.finalize()),
                             chunks: chunks)
        }

        private mutating func closeChunk() {
            chunks.append(Chunk(sha256: ChunkPlan.hex(current.finalize()), offset: total - currentBytes,
                                bytes: currentBytes))
            current = SHA256()
            currentBytes = 0
        }
    }

    /// Whether the plan has the shape the contract gives a part: at least one chunk, every chunk but
    /// the last exactly `chunkBytes`, the last no longer than that and not empty, each beginning
    /// where the one before ended, and the lengths adding up to the part. It cannot tell whether
    /// the digests are true; only the bytes can.
    var isWellFormed: Bool {
        guard chunkBytes > 0, bytes > 0, bytes <= Self.maximumSafeInteger, Self.isDigest(sha256),
              let last = chunks.last, last.bytes > 0, last.bytes <= chunkBytes else { return false }
        var offset: Int64 = 0
        for chunk in chunks {
            guard Self.isDigest(chunk.sha256), chunk.offset == offset else { return false }
            offset += chunk.bytes
        }
        return offset == bytes && chunks.dropLast().allSatisfy { $0.bytes == chunkBytes }
    }

    /// The chunk files to send: one for each different digest, in the order first met. Two chunks
    /// with the same bytes are one file.
    var files: [Chunk] {
        var seen: Set<String> = []
        return chunks.filter { seen.insert($0.sha256).inserted }
    }

    /// How many of the part's bytes are in chunks the office has been served.
    func servedBytes(_ served: Set<String>) -> Int64 {
        chunks.filter { served.contains($0.sha256) }.reduce(0) { $0 + $1.bytes }
    }

    /// Whether these are the part's bytes: cut as planned, every chunk and the whole match their
    /// digests. The check the receiving side makes before it says it has the part.
    func matches(_ part: Data) -> Bool {
        ChunkPlan.plan(part, chunkBytes: chunkBytes) == self
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
