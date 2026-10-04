import CryptoKit
import XCTest
@testable import OpenGlasses

/// A media part cut into chunks named by digest (Contracts/recorded-session.md §3).
final class ChunkPlanTests: XCTestCase {

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes that differ from chunk to chunk and are the same on every run.
    private func media(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    }

    func testEveryChunkButTheLastIsExactlyTheChunkSize() throws {
        let part = media(2_500)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        XCTAssertEqual(plan.chunks.map(\.bytes), [1_000, 1_000, 500])
        XCTAssertEqual(plan.chunks.map(\.offset), [0, 1_000, 2_000])
        XCTAssertEqual(plan.bytes, 2_500)
        XCTAssertEqual(plan.chunkBytes, 1_000)
        XCTAssertTrue(plan.isWellFormed)
    }

    func testEachChunkIsNamedByTheDigestOfItsOwnBytes() throws {
        let part = media(2_500)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        XCTAssertEqual(plan.chunks.map(\.sha256),
                       [sha(part[0..<1_000]), sha(part[1_000..<2_000]), sha(part[2_000..<2_500])])
        XCTAssertEqual(plan.chunks[0].path, "media/\(sha(part[0..<1_000])).chunk")
        XCTAssertEqual(ChunkPlan.path(sha256: "ab"), "media/ab.chunk")
    }

    func testTheChunksJoinedInOrderAreThePartAndGiveItsDigest() throws {
        let part = media(2_500)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        let joined = plan.chunks.reduce(into: Data()) { whole, chunk in
            whole.append(part[Int(chunk.offset)..<Int(chunk.offset + chunk.bytes)])
        }
        XCTAssertEqual(joined, part)
        XCTAssertEqual(sha(joined), plan.sha256)
        XCTAssertEqual(plan.sha256, sha(part))
    }

    func testAKnownDigest() throws {
        // SHA-256 of the three bytes "abc", the standard test vector.
        let plan = try XCTUnwrap(ChunkPlan.plan(Data("abc".utf8), chunkBytes: 2))
        XCTAssertEqual(plan.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(plan.chunks.map(\.sha256), [
            "fb8e20fc2e4c3f248c60c39bd652f3c1347298bb977b8b4d5903b85055620603",  // "ab"
            "2e7d2c03a9507ae265ecf5b5356885a53393a2029d241394997265a1a25aefc6",  // "c"
        ])
    }

    func testAPartThatIsAWholeNumberOfChunksHasNoShortChunk() throws {
        let plan = try XCTUnwrap(ChunkPlan.plan(media(3_000), chunkBytes: 1_000))
        XCTAssertEqual(plan.chunks.map(\.bytes), [1_000, 1_000, 1_000])
        XCTAssertTrue(plan.isWellFormed)
    }

    func testAPartSmallerThanAChunkIsOneChunkWithThePartsDigest() throws {
        let part = media(10)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        XCTAssertEqual(plan.chunks.count, 1)
        XCTAssertEqual(plan.chunks[0].sha256, plan.sha256)
        XCTAssertEqual(plan.chunks[0].bytes, 10)
    }

    func testThePlanIsTheSameHoweverTheBytesArrive() throws {
        let part = media(2_500)
        var builder = try XCTUnwrap(ChunkPlan.Builder(chunkBytes: 1_000))
        for range in [0..<1, 1..<999, 999..<1_000, 1_000..<2_400, 2_400..<2_400, 2_400..<2_500] {
            builder.append(part[range])
        }
        XCTAssertEqual(builder.finish(), ChunkPlan.plan(part, chunkBytes: 1_000))
    }

    func testAnEmptyPartOrAChunkSizeThatIsNotPositiveHasNoPlan() {
        XCTAssertNil(ChunkPlan.plan(Data(), chunkBytes: 1_000))
        XCTAssertNil(ChunkPlan.plan(media(10), chunkBytes: 0))
        XCTAssertNil(ChunkPlan.plan(media(10), chunkBytes: -1))
        XCTAssertNil(ChunkPlan.Builder(chunkBytes: ChunkPlan.maximumSafeInteger + 1))
        var builder = ChunkPlan.Builder(chunkBytes: 4)
        XCTAssertNil(builder?.finish())
    }

    func testTheProposedChunkSizeIsThirtyTwoMebibytes() {
        XCTAssertEqual(ChunkPlan.proposedChunkBytes, 33_554_432)
    }

    func testTwoChunksWithTheSameBytesAreOneFile() throws {
        let part = Data(repeating: 7, count: 2_000) + Data(repeating: 9, count: 300)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        XCTAssertEqual(plan.chunks.count, 3)
        XCTAssertEqual(plan.chunks[0].sha256, plan.chunks[1].sha256)
        XCTAssertEqual(plan.files.map(\.sha256), [plan.chunks[0].sha256, plan.chunks[2].sha256])
    }

    func testProgressCountsTheBytesOfChunksServed() throws {
        let plan = try XCTUnwrap(ChunkPlan.plan(media(2_500), chunkBytes: 1_000))
        XCTAssertEqual(plan.servedBytes([]), 0)
        XCTAssertEqual(plan.servedBytes([plan.chunks[2].sha256]), 500)
        XCTAssertEqual(plan.servedBytes(Set(plan.chunks.map(\.sha256))), 2_500)
        XCTAssertEqual(plan.servedBytes(["not one of its chunks"]), 0)
    }

    func testOnlyThePartsOwnBytesMatchThePlan() throws {
        let part = media(2_500)
        let plan = try XCTUnwrap(ChunkPlan.plan(part, chunkBytes: 1_000))
        XCTAssertTrue(plan.matches(part))
        var changed = part
        changed[1_500] ^= 1
        XCTAssertFalse(plan.matches(changed), "one bit in the middle chunk")
        XCTAssertFalse(plan.matches(part.dropLast()), "a byte short")
        XCTAssertFalse(plan.matches(part + Data([0])), "a byte long")
    }

    func testAPlanThatDoesNotHaveTheContractsShapeIsNotWellFormed() throws {
        let good = try XCTUnwrap(ChunkPlan.plan(media(2_500), chunkBytes: 1_000))
        func plan(_ chunks: [ChunkPlan.Chunk], bytes: Int64 = 2_500, sha256: String? = nil) -> ChunkPlan {
            ChunkPlan(chunkBytes: 1_000, bytes: bytes, sha256: sha256 ?? good.sha256, chunks: chunks)
        }
        func chunk(_ index: Int, offset: Int64? = nil, bytes: Int64? = nil, sha256: String? = nil) -> ChunkPlan.Chunk {
            ChunkPlan.Chunk(sha256: sha256 ?? good.chunks[index].sha256, offset: offset ?? good.chunks[index].offset,
                            bytes: bytes ?? good.chunks[index].bytes)
        }
        XCTAssertTrue(plan(good.chunks).isWellFormed)
        XCTAssertFalse(plan([]).isWellFormed, "no chunks")
        XCTAssertFalse(plan([chunk(0), chunk(2, offset: 1_000), chunk(1, offset: 1_500)]).isWellFormed, "a short chunk that is not the last")
        XCTAssertFalse(plan([chunk(0), chunk(1), chunk(2, bytes: 1_001)], bytes: 3_001).isWellFormed, "a last chunk too long")
        XCTAssertFalse(plan([chunk(0), chunk(1), chunk(2, bytes: 0)], bytes: 2_000).isWellFormed, "an empty last chunk")
        XCTAssertFalse(plan([chunk(0), chunk(1), chunk(2, offset: 2_001)]).isWellFormed, "a chunk out of place")
        XCTAssertFalse(plan(good.chunks, bytes: 2_499).isWellFormed, "lengths that do not add up")
        XCTAssertFalse(plan([chunk(0), chunk(1), chunk(2, sha256: "ABC")]).isWellFormed, "a name that is not a digest")
        XCTAssertFalse(plan(good.chunks, sha256: good.sha256.uppercased()).isWellFormed, "an upper-case digest")
    }
}
