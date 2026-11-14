import XCTest
@testable import OpenGlasses

/// Plan LT §7 — an odd-length chunk of 16-bit audio from a realtime provider cannot misalign the
/// rest of the reply: the byte past the last whole sample is held for the next chunk.
final class RealtimeAudioCarryTests: XCTestCase {

    /// Little-endian 16-bit samples as bytes.
    private func bytes(_ samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func samples(_ data: Data) -> [Int16] {
        stride(from: 0, to: data.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8)
        }
    }

    func testEvenChunksPassStraightThrough() {
        var carry = PCMByteCarry(frameBytes: 2)
        let chunk = bytes([1, -2, 300])
        XCTAssertEqual(carry.aligned(chunk), chunk)
        XCTAssertEqual(carry.aligned(bytes([7])), bytes([7]))
        XCTAssertTrue(carry.held.isEmpty)
    }

    func testOddThenOddRejoinsTheSplitSample() {
        let reply = bytes([1000, -1000, 12345, -32768, 42])   // 10 bytes
        var carry = PCMByteCarry(frameBytes: 2)
        let first = carry.aligned(reply.prefix(3))            // one sample and half of the next
        XCTAssertEqual(samples(first), [1000])
        XCTAssertEqual(carry.held.count, 1)
        let second = carry.aligned(reply.suffix(from: 3))     // the other 7 bytes
        XCTAssertEqual(samples(second), [-1000, 12345, -32768, 42], "every later sample on its boundary")
        XCTAssertTrue(carry.held.isEmpty)
    }

    func testOddThenOddThenOddKeepsAlignment() {
        let reply = bytes((0..<9).map { Int16($0 * 1111) })   // 18 bytes
        var carry = PCMByteCarry(frameBytes: 2)
        var out = Data()
        var offset = 0
        for size in [5, 7, 3, 3] {
            out.append(carry.aligned(reply.subdata(in: offset..<(offset + size))))
            offset += size
        }
        XCTAssertEqual(out, reply)
    }

    func testOddThenInterruptDropsTheHalfSample() {
        var carry = PCMByteCarry(frameBytes: 2)
        _ = carry.aligned(bytes([5, 6]).prefix(3))
        XCTAssertEqual(carry.held.count, 1)
        carry.reset()                                          // barge-in, a new response or a stop
        XCTAssertEqual(carry.aligned(bytes([9, 10])), bytes([9, 10]),
                       "the next reply starts on its own boundary")
    }

    func testALoneByteWaitsForItsPartner() {
        var carry = PCMByteCarry(frameBytes: 2)
        XCTAssertTrue(carry.aligned(Data([0x34])).isEmpty)
        XCTAssertEqual(carry.aligned(Data([0x12])), Data([0x34, 0x12]))
    }

    func testStereoFramesHoldUpToThreeBytes() {
        var carry = PCMByteCarry(frameBytes: 4)
        XCTAssertTrue(carry.aligned(Data([1, 2, 3])).isEmpty)
        XCTAssertEqual(carry.aligned(Data([4, 5])), Data([1, 2, 3, 4]))
        XCTAssertEqual(carry.held, Data([5]))
    }

    // MARK: - The engine, read from source (it needs an audio session)

    func testTheEngineCarriesAndClearsAtEachRestart() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources/Services/Audio/RealtimeAudioEngine.swift")
        let code = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(code.contains("let data = pcmCarry.aligned(chunk)"), "every received chunk is aligned")
        func body(_ signature: String) throws -> String {
            let start = try XCTUnwrap(code.range(of: signature), signature)
            let rest = code[start.upperBound...]
            return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
        }
        XCTAssertTrue(try body("func resetPlaybackProgress()").contains("pcmCarry.reset()"), "a new response")
        XCTAssertTrue(try body("private func stopPlaybackOnQueue()").contains("pcmCarry.reset()"), "an interruption")
        XCTAssertTrue(try body("func stopCapture()").contains("pcmCarry.reset()"), "a stop")
    }
}
