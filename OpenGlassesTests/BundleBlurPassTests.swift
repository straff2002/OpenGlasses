import AVFoundation
import UIKit
import XCTest
@testable import OpenGlasses

/// The blur pass over a real, small movie made in the test (Plan HE §1, "Blur when required").
///
/// The movie is a second of 128×128 video — twenty-four frames, each a flat grey whose brightness
/// is its number, with one black corner so a picture turned over would show — with or without a
/// second of sound. The filter is a fake that reads which frame it was handed and hands back a
/// marked copy: the top half white. So what comes out can be read back and asked, frame by frame:
/// did this go through the filter, which frame is it, and is it where it was.
///
/// Nothing here detects a face. Whether the app's own blur finds faces is the blur's own tests'
/// business; this is about what the pass does with what a filter says.
@MainActor
final class BundleBlurPassTests: XCTestCase {

    private static let side = 128
    private static let frameCount = 24
    private static let framesPerSecond: Int32 = 24
    /// Not the recorder's own 16 kHz at 64 kbps: the simulator's encoder refuses that pairing
    /// ("the encoding parameters are not supported"). The pass copies packets and does not care.
    private static let soundRate: Double = 44_100

    /// The grey a frame is painted: its number, eight levels apart, so a lossy encode cannot
    /// make one frame read as its neighbour.
    /// It starts well above black, so the first frame cannot be taken for no picture at all.
    private nonisolated static func level(_ frame: Int) -> Int { 32 + 8 * frame }
    private nonisolated static func frame(ofLevel level: Int) -> Int { Int((Double(level - 32) / 8).rounded()) }

    // MARK: - The fake filter

    private final class FakeFilter {
        /// The frame each call was handed, in the order the calls came.
        var handed: [Int] = []
        var refuses: Set<Int> = []
        /// Frames handed back at half the size.
        var shrinks: Set<Int> = []
        /// The blur stops being available once this many frames have been handed over.
        var availableFor = Int.max
        var availabilityChecks = 0

        var isAvailable: Bool {
            availabilityChecks += 1
            return handed.count < availableFor
        }

        func apply(_ image: UIImage) -> UIImage? {
            let frame = BundleBlurPassTests.frame(ofLevel: BundleBlurPassTests.green(in: image, x: 32, y: 96))
            handed.append(frame)
            if refuses.contains(frame) { return nil }
            let side = CGFloat(BundleBlurPassTests.side) / (shrinks.contains(frame) ? 2 : 1)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side / 2))
            }
        }

        var pass: BundleBlurPass {
            BundleBlurPass(filter: .init(isAvailable: { self.isAvailable }, apply: { self.apply($0) }))
        }
    }

    /// The green of one pixel of an image, counted from the top left.
    private nonisolated static func green(in image: UIImage, x: Int, y: Int) -> Int {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return -1 }
        return Int(bytes[y * cgImage.bytesPerRow + x * 4 + 1])
    }

    // MARK: - The world

    private var folder: URL!
    private var filter: FakeFilter!

    override func setUp() async throws {
        try await super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleBlurPassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        filter = FakeFilter()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    private var output: URL { folder.appendingPathComponent("part-1.blurring.mp4") }

    // MARK: - Making a movie

    private struct NotMade: Error {}

    /// Writes the test's movie: H.264 as the recorder encodes it, and AAC when there is sound.
    private func makeMovie(sound: Bool, name: String = "part-1.mp4") async throws -> URL {
        let url = folder.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let pictures = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.side,
            AVVideoHeightKey: Self.side,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        pictures.expectsMediaDataInRealTime = false
        writer.add(pictures)
        var soundInput: AVAssetWriterInput?
        if sound {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.soundRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            soundInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? NotMade() }
        writer.startSession(atSourceTime: .zero)
        guard let pool = BundleBlurPass.pixelBufferPool(width: Self.side, height: Self.side) else { throw NotMade() }

        var frame = 0
        var soundBlock = 0
        let soundBlocks = sound ? 10 : 0   // ten tenths of a second
        var waited = 0
        while frame < Self.frameCount || soundBlock < soundBlocks {
            guard writer.status == .writing else { throw writer.error ?? NotMade() }
            var moved = false
            if frame < Self.frameCount, pictures.isReadyForMoreMediaData {
                let time = CMTime(value: CMTimeValue(frame), timescale: Self.framesPerSecond)
                guard let buffer = BundleBlurPass.pixelBuffer(drawing: try Self.picture(frame), from: pool),
                      let sample = BundleBlurPass.sample(buffer, at: time,
                                                         lasting: CMTime(value: 1, timescale: Self.framesPerSecond)),
                      pictures.append(sample) else { throw writer.error ?? NotMade() }
                frame += 1
                if frame == Self.frameCount { pictures.markAsFinished() }
                moved = true
            }
            if let soundInput, soundBlock < soundBlocks, soundInput.isReadyForMoreMediaData {
                guard soundInput.append(try Self.sound(block: soundBlock)) else { throw writer.error ?? NotMade() }
                soundBlock += 1
                if soundBlock == soundBlocks { soundInput.markAsFinished() }
                moved = true
            }
            if !moved {
                waited += 1
                guard waited < 5_000 else { throw NotMade() }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? NotMade() }
        return url
    }

    /// One frame: a flat grey that says which frame it is, with the bottom right corner black.
    private static func picture(_ frame: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let side = CGFloat(Self.side)
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor(white: CGFloat(level(frame)) / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIColor.black.setFill()
            context.fill(CGRect(x: side / 2, y: side / 2, width: side / 2, height: side / 2))
        }
        guard let cgImage = image.cgImage else { throw NotMade() }
        return cgImage
    }

    /// A tenth of a second of a tone, as the microphone's samples would arrive.
    private static func sound(block: Int) throws -> CMSampleBuffer {
        let count = Int(soundRate / 10)
        var description = AudioStreamBasicDescription(
            mSampleRate: soundRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let samples: [Int16] = (0..<count).map { index in
            Int16(8_000 * sin(2 * .pi * 440 * Double(block * count + index) / soundRate))
        }
        let length = count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                           offsetToData: 0, dataLength: length, flags: 0,
                                           blockBufferOut: &blockBuffer)
        guard let format, let blockBuffer else { throw NotMade() }
        try samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0,
                                                dataLength: length) == kCMBlockBufferNoErr else { throw NotMade() }
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(block * count),
                                                              timescale: CMTimeScale(soundRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw NotMade() }
        return sample
    }

    // MARK: - Reading a movie back

    /// One decoded frame of a movie: when it is shown and what three of its pixels are.
    private struct Seen: Equatable {
        /// Milliseconds from the start of the movie.
        let at: Int
        /// The middle of the top half: white where the fake filter marked the frame.
        let top: Int
        /// The bottom left: the grey that says which frame it is.
        let bottomLeft: Int
        /// The bottom right: black, if the picture is the right way up and round.
        let bottomRight: Int

        var marked: Bool { top >= 236 }
        var frame: Int { BundleBlurPassTests.frame(ofLevel: bottomLeft) }
        /// Black all over: what a decoder shows for a stretch of a track that holds no frame —
        /// the start of a part whose first frames were dropped. Not a picture of anything.
        var isBlank: Bool { top <= 16 && bottomLeft <= 16 && bottomRight <= 16 }
    }

    /// The frames a movie really holds: a decoder's black stand-in for a stretch with no frame is
    /// not one of them. Such a stand-in may only come before the first real frame.
    private func kept(_ seen: [Seen], file: StaticString = #filePath, line: UInt = #line) -> [Seen] {
        let real = seen.filter { !$0.isBlank }
        let firstReal = real.first?.at ?? .max
        XCTAssertTrue(seen.filter(\.isBlank).allSatisfy { $0.at < firstReal }, "a blank picture among the real ones",
                      file: file, line: line)
        return real
    }

    private func pictures(in url: URL) async throws -> [Seen] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var seen: [Seen] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0, let buffer = CMSampleBufferGetImageBuffer(sample),
                  let image = BundleBlurPass.image(from: buffer) else { continue }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            seen.append(Seen(at: Int((time * 1_000).rounded()), top: Self.green(in: image, x: 64, y: 32),
                             bottomLeft: Self.green(in: image, x: 32, y: 96),
                             bottomRight: Self.green(in: image, x: 96, y: 96)))
        }
        XCTAssertEqual(reader.status, .completed)
        return seen
    }

    /// The sound of a movie exactly as it is stored: every packet's bytes, in order.
    private func soundBytes(in url: URL) async throws -> (packets: Int, bytes: Data, seconds: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var packets = 0
        var bytes = Data()
        while let sample = output.copyNextSampleBuffer() {
            packets += CMSampleBufferGetNumSamples(sample)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var piece = Data(count: CMBlockBufferGetDataLength(block))
            let copied = piece.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            XCTAssertEqual(copied, kCMBlockBufferNoErr)
            bytes.append(piece)
        }
        XCTAssertEqual(reader.status, .completed)
        return (packets, bytes, CMTimeGetSeconds(try await track.load(.timeRange).duration))
    }

    private func milliseconds(_ frame: Int) -> Int {
        Int((Double(frame) * 1_000 / Double(Self.framesPerSecond)).rounded())
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - The movie the tests stand on

    /// If the encoder in this test process cannot make or read back the movie, everything below
    /// would be passing or failing on nothing. This says so on its own line.
    func testTheTestsOwnMovieIsWhatItIsMeantToBe() async throws {
        let movie = try await makeMovie(sound: true)
        let seen = try await pictures(in: movie)
        XCTAssertEqual(seen.map(\.frame), Array(0..<Self.frameCount), "each frame reads back as its own number")
        XCTAssertEqual(seen.map(\.at), (0..<Self.frameCount).map(milliseconds))
        XCTAssertFalse(seen.contains(where: \.marked), "nothing is marked until a filter marks it")
        XCTAssertTrue(seen.allSatisfy { $0.bottomRight <= 40 })
        let sound = try await soundBytes(in: movie)
        XCTAssertGreaterThan(try XCTUnwrap(sound).packets, 10)
    }

    // MARK: - Every frame, through the filter

    func testEveryFrameGoesThroughTheFilterOnceAndInOrder() async throws {
        let movie = try await makeMovie(sound: true)
        let before = try Data(contentsOf: movie)
        var fractions: [Double] = []

        let result = await filter.pass.run(part: movie, output: output) { fractions.append($0) }

        let report = try result.get()
        XCTAssertEqual(report, .init(framesWritten: 24, framesDropped: 0, droppedRuns: [], keptSound: true))
        XCTAssertEqual(filter.handed, Array(0..<Self.frameCount), "each frame handed to the filter once, in order")

        let seen = try await pictures(in: output)
        XCTAssertEqual(seen.count, Self.frameCount)
        XCTAssertTrue(seen.allSatisfy(\.marked), "a frame in the output did not come back from the filter")
        XCTAssertEqual(seen.map(\.frame), Array(0..<Self.frameCount))
        XCTAssertEqual(seen.map(\.at), (0..<Self.frameCount).map(milliseconds), "every picture is where it was")
        XCTAssertTrue(seen.allSatisfy { $0.bottomRight <= 40 }, "the picture is the right way up and round")

        XCTAssertEqual(try Data(contentsOf: movie), before, "the recorded part is not touched")
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertTrue(fractions.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    func testTheSoundIsCarriedOverAsItWas() async throws {
        let movie = try await makeMovie(sound: true)
        let recordedSound = try await soundBytes(in: movie)
        let recorded = try XCTUnwrap(recordedSound)

        _ = try await filter.pass.run(part: movie, output: output).get()

        let blurredSound = try await soundBytes(in: output)

        let blurred = try XCTUnwrap(blurredSound, "the sound is gone")
        XCTAssertEqual(blurred.packets, recorded.packets)
        XCTAssertEqual(blurred.bytes, recorded.bytes, "the same packets, not sound encoded a second time")
        XCTAssertEqual(blurred.seconds, recorded.seconds, accuracy: 0.001, "and the same length")
    }

    func testAPartWithNoSoundIsBlurredAndHasNone() async throws {
        let movie = try await makeMovie(sound: false)
        let report = try await filter.pass.run(part: movie, output: output).get()
        XCTAssertEqual(report, .init(framesWritten: 24, framesDropped: 0, keptSound: false))
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen.map(\.frame), Array(0..<Self.frameCount))
        XCTAssertTrue(seen.allSatisfy(\.marked))
        let sound = try await soundBytes(in: output)
        XCTAssertNil(sound)
    }

    // MARK: - A frame the filter cannot process

    func testAFrameTheFilterRefusesIsDroppedAndCountedAndIsNotInTheOutput() async throws {
        let movie = try await makeMovie(sound: true)
        filter.refuses = [3, 4, 5, 11]

        let report = try await filter.pass.run(part: movie, output: output).get()

        XCTAssertEqual(report.framesWritten, 20)
        XCTAssertEqual(report.framesDropped, 4)
        XCTAssertTrue(report.keptSound)
        XCTAssertEqual(filter.handed, Array(0..<Self.frameCount), "a refused frame was still asked about, once")

        let kept = (0..<Self.frameCount).filter { !filter.refuses.contains($0) }
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen.map(\.frame), kept, "a refused frame is in the output, or a kept one is not")
        XCTAssertTrue(seen.allSatisfy(\.marked))
        XCTAssertEqual(seen.map(\.at), kept.map(milliseconds), "the frames that are kept stay where they were")

        // Where the pictures were dropped: from the first one dropped to the next one kept.
        XCTAssertEqual(report.droppedRuns.count, 2)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.first).from, 3.0 / 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.first).to, 6.0 / 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.last).from, 11.0 / 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.last).to, 12.0 / 24, accuracy: 0.001)

        // The sound does not lose anything for it.
        let recordedSound = try await soundBytes(in: movie)
        let recorded = try XCTUnwrap(recordedSound)
        let blurredSound = try await soundBytes(in: output)
        let blurred = try XCTUnwrap(blurredSound)
        XCTAssertEqual(blurred.bytes, recorded.bytes)
    }

    func testFramesDroppedAtTheEndRunToTheEndOfTheVideo() async throws {
        let movie = try await makeMovie(sound: false)
        filter.refuses = [0, 22, 23]
        let report = try await filter.pass.run(part: movie, output: output).get()
        XCTAssertEqual(report.framesWritten, 21)
        XCTAssertEqual(report.framesDropped, 3)
        XCTAssertEqual(report.droppedRuns.count, 2)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.first).from, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.first).to, 1.0 / 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.last).from, 22.0 / 24, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.droppedRuns.last).to, 1, accuracy: 0.001)
        let seen = kept(try await pictures(in: output))
        XCTAssertEqual(seen.map(\.frame), Array(1..<22))
        XCTAssertTrue(seen.allSatisfy(\.marked))
        XCTAssertEqual(seen.map(\.at), (1..<22).map(milliseconds), "the first kept frame is not moved to the start")
    }

    /// What the filter hands back is only written when it is a picture of this part. Anything at
    /// another size is not, and is treated as a frame the filter could not process.
    func testAFrameHandedBackAtAnotherSizeIsDropped() async throws {
        let movie = try await makeMovie(sound: false)
        filter.shrinks = [7]
        let report = try await filter.pass.run(part: movie, output: output).get()
        XCTAssertEqual(report.framesWritten, 23)
        XCTAssertEqual(report.framesDropped, 1)
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen.map(\.frame), (0..<Self.frameCount).filter { $0 != 7 })
    }

    // MARK: - Every frame refused

    /// Chosen: when no picture can be blurred the sound is kept by itself — it is what was said
    /// on the job, and the transcript is made from it.
    func testAPartWithEveryFrameRefusedKeepsItsSoundAndNoPictures() async throws {
        let movie = try await makeMovie(sound: true)
        let recordedSound = try await soundBytes(in: movie)
        let recorded = try XCTUnwrap(recordedSound)
        filter.refuses = Set(0..<Self.frameCount)

        let report = try await filter.pass.run(part: movie, output: output).get()

        XCTAssertEqual(report.framesWritten, 0)
        XCTAssertEqual(report.framesDropped, 24)
        XCTAssertTrue(report.keptSound)
        XCTAssertFalse(report.keptNothing)
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen, [], "there is a picture in a part none of whose pictures could be blurred")
        let videoTracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty)
        let blurredSound = try await soundBytes(in: output)
        let blurred = try XCTUnwrap(blurredSound)
        XCTAssertEqual(blurred.bytes, recorded.bytes)
        XCTAssertEqual(blurred.seconds, recorded.seconds, accuracy: 0.001)
    }

    /// And with no sound either there is nothing to keep: no file, and the report says so.
    func testAPartWithEveryFrameRefusedAndNoSoundLeavesNothing() async throws {
        let movie = try await makeMovie(sound: false)
        filter.refuses = Set(0..<Self.frameCount)
        let report = try await filter.pass.run(part: movie, output: output).get()
        XCTAssertEqual(report, .init(framesWritten: 0, framesDropped: 24, keptSound: false))
        XCTAssertTrue(report.keptNothing)
        XCTAssertFalse(exists(output))
        XCTAssertTrue(exists(movie), "the pass never removes the recorded part")
    }

    // MARK: - Interrupted

    func testAnInterruptedPassLeavesTheRecordedPartAndNoOutput() async throws {
        let movie = try await makeMovie(sound: true)
        let before = try Data(contentsOf: movie)
        filter.availableFor = 10

        let result = await filter.pass.run(part: movie, output: output)

        XCTAssertEqual(result, .failure(.interrupted))
        XCTAssertEqual(filter.handed.count, 10, "no frame is handed to a blur that has stopped")
        XCTAssertFalse(exists(output), "half a blurred part was left behind")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["part-1.mp4"])
        XCTAssertEqual(try Data(contentsOf: movie), before)

        // And it can simply be done again.
        filter = FakeFilter()
        let report = try await filter.pass.run(part: movie, output: output).get()
        XCTAssertEqual(report.framesWritten, 24)
    }

    /// A frame that comes back refused at the moment the blur stops is not a dropped frame: the
    /// blur did not look at it. The pass is interrupted, and nothing is counted.
    func testAFrameRefusedBecauseTheBlurStoppedIsNotCountedAsDropped() async throws {
        let movie = try await makeMovie(sound: false)
        filter.refuses = [9]
        filter.availableFor = 10   // available before frame 9 is handed over, not after
        let result = await filter.pass.run(part: movie, output: output)
        XCTAssertEqual(result, .failure(.interrupted))
        XCTAssertEqual(filter.handed.count, 10)
        XCTAssertFalse(exists(output))
    }

    func testAnOutputLeftFromBeforeIsReplacedNotAddedTo() async throws {
        let movie = try await makeMovie(sound: false)
        try Data("left over from an earlier try".utf8).write(to: output)
        _ = try await filter.pass.run(part: movie, output: output).get()
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen.count, Self.frameCount)
    }

    // MARK: - What it will not start on

    func testWithoutRoomForTheBlurredCopyNothingIsWritten() async throws {
        let movie = try await makeMovie(sound: true)
        var pass = filter.pass
        pass.freeBytes = { _ in 1_024 }
        let result = await pass.run(part: movie, output: output)
        XCTAssertEqual(result, .failure(.notEnoughStorage))
        XCTAssertTrue(filter.handed.isEmpty)
        XCTAssertFalse(exists(output))
    }

    func testAFileThatIsNotARecordedPartIsRefused() async throws {
        let notAMovie = folder.appendingPathComponent("part-9.mp4")
        try Data(repeating: 7, count: 4_096).write(to: notAMovie)
        let result = await filter.pass.run(part: notAMovie, output: output)
        XCTAssertEqual(result, .failure(.unreadable))
        XCTAssertFalse(exists(output))

        let missing = await filter.pass.run(part: folder.appendingPathComponent("part-10.mp4"), output: output)
        XCTAssertEqual(missing, .failure(.unreadable))
    }

    // MARK: - The app's own blur

    private final class RecordingStillFilter: StillImageFiltering {
        var scopes: [PrivacyFilterScope] = []
        var answer: UIImage?
        func filteredOrUnavailable(_ image: UIImage, for scope: PrivacyFilterScope) -> UIImage? {
            scopes.append(scope)
            return answer
        }
    }

    /// In the app the pass asks the one chokepoint, under the scope that is blurred whatever the
    /// wearer's setting says — and takes its answer as it is, a refusal included.
    func testTheAppsPassAsksTheChokepointUnderTheMandatoryScope() throws {
        let still = RecordingStillFilter()
        var available = true
        let pass = BundleBlurPass.app(filter: still, isAvailable: { available })
        let picture = UIImage(cgImage: try Self.picture(0))

        XCTAssertNil(pass.filter.apply(picture), "the chokepoint refused, so the pass has no picture")
        still.answer = picture
        XCTAssertTrue(pass.filter.apply(picture) === picture)
        XCTAssertEqual(still.scopes, [.officeRecordingBlur, .officeRecordingBlur])
        XCTAssertTrue(PrivacyFilterScope.officeRecordingBlur.isMandatory)

        XCTAssertTrue(pass.filter.isAvailable())
        available = false
        XCTAssertFalse(pass.filter.isAvailable())
    }

    /// The app's real blur, with the wearer's setting **off** and the blur unable to run. If the
    /// setting being off were a passthrough here — as it rightly is for every other consumer —
    /// every frame would be written unblurred. Instead the pass stops.
    func testWithTheWearersSettingOffTheRealBlurStillRefusesRatherThanPassingFramesThrough() async throws {
        let movie = try await makeMovie(sound: true)
        let service = PrivacyFilterService()
        service.isEnabled = false
        service.noteScenePhase(.background)

        let honest = BundleBlurPass.app(filter: service, isAvailable: { !service.isSuspendedForBackground })
        let stopped = await honest.run(part: movie, output: output)
        XCTAssertEqual(stopped, .failure(.interrupted))
        XCTAssertFalse(exists(output))

        // Even told, wrongly, that the blur can run: the blur itself refuses every frame, and
        // none is written.
        let misled = BundleBlurPass.app(filter: service, isAvailable: { true })
        let report = try await misled.run(part: movie, output: output).get()
        XCTAssertEqual(report.framesWritten, 0)
        XCTAssertEqual(report.framesDropped, 24)
        let seen = try await pictures(in: output)
        XCTAssertEqual(seen, [])
    }
}
