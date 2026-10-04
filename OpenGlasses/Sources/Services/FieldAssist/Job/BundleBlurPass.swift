import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import UIKit

/// Blurs one recorded part of a job before its bundle is sealed, where the organisation requires
/// faces blurred before a recording goes to its office (Plan HE §1, "Blur when required").
///
/// It reads a recorded part — an MP4 with pictures, and sound if it has any — and writes a new
/// file beside it:
///
/// - **Every picture written has been through the face blur.** Each frame is decoded, handed to
///   the filter, and only what the filter hands back is encoded. There is no path by which a
///   decoded frame reaches the encoder without having been returned by the filter.
/// - **A picture the filter cannot process is dropped and counted**, never written as it was. So
///   is one the filter hands back at another size, and one that cannot be decoded.
/// - **The sound is carried over as it is** — the same packets, not decoded and encoded again —
///   and every picture keeps the time it had, so sound and pictures stay in step and a dropped
///   picture leaves the one before it showing a little longer.
/// - **Only the pictures and the first sound track are carried.** Anything else in the file is
///   not: a second video track would be pictures nobody blurred, so a part with one is refused.
/// - **When the blur stops being able to run** — the app leaves the foreground, the phone locks —
///   the pass stops, removes what it had written, and says it was interrupted. A frame refused
///   because the blur had become unavailable is not counted as dropped: the part is done again.
/// - **It checks what it made** before saying it succeeded: the file it wrote holds as many
///   pictures as it handed to the encoder and as many packets of sound as the recorded part,
///   and it plays. On anything else it removes its output and fails.
///
/// It never touches the recorded part. Removing that, once the blurred replacement is in place
/// and written down, is the caller's (`JobRecordingCoordinator`).
///
/// When every picture is dropped: with sound, the output is the sound alone; without, there is no
/// output and the report says nothing was kept.
struct BundleBlurPass {

    /// The face blur, as the pass needs it.
    struct Filter {
        /// Whether the blur can be relied on at this moment. Asked before every picture, and
        /// again when one comes back refused, to tell "this picture could not be processed"
        /// from "the blur has stopped running".
        var isAvailable: @MainActor () -> Bool
        /// The picture with faces blurred, or nil when it could not be processed.
        var apply: @MainActor (UIImage) -> UIImage?
    }

    enum Failure: Error, Equatable {
        /// The blur became unavailable, or the work was cancelled. Nothing was kept.
        case interrupted
        /// The recorded part could not be read, or is not a part this can blur.
        case unreadable
        /// Not enough room for the blurred copy beside the recorded part.
        case notEnoughStorage
        /// The blurred part could not be written.
        case couldNotWrite
        /// What was written is not what should have been: the counts do not match, or it does
        /// not play.
        case didNotCheckOut
    }

    let filter: Filter
    /// The room there is for a new file in a folder, when the system says.
    var freeBytes: (URL) -> Int64? = BundleBlurPass.volumeFreeBytes

    /// Room asked for beyond the recorded part's own size: the blurred copy is about as large.
    static let storageMargin: Int64 = 32 << 20

    /// Blurs `part` into `output`. On success with pictures or sound kept, `output` is the blurred
    /// part; when nothing was kept, and on every failure, there is nothing at `output`.
    func run(part: URL, output: URL,
             progress: @escaping @MainActor (Double) -> Void = { _ in }) async -> Result<BlurredPart.Report, Failure> {
        try? FileManager.default.removeItem(at: output)
        do {
            return .success(try await blur(part: part, output: output, progress: progress))
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError || Task.isCancelled { return .failure(.interrupted) }
            return .failure((error as? Failure) ?? .couldNotWrite)
        }
    }

    // MARK: - The pass

    private enum Answer {
        case blurred(UIImage)
        case refused
        case unavailable
    }

    private func blur(part: URL, output: URL,
                      progress: @escaping @MainActor (Double) -> Void) async throws -> BlurredPart.Report {
        let asset = AVURLAsset(url: part)
        let videoTracks: [AVAssetTrack]
        let audioTrack: AVAssetTrack?
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        } catch {
            throw Failure.unreadable
        }
        // One video track, as the recorder writes. A second would be pictures this never blurs.
        guard videoTracks.count <= 1 else { throw Failure.unreadable }
        let videoTrack = videoTracks.first

        let partBytes = Self.size(of: part)
        guard partBytes > 0 else { throw Failure.unreadable }
        if let free = freeBytes(output.deletingLastPathComponent()), free < partBytes + Self.storageMargin {
            throw Failure.notEnoughStorage
        }

        let sourceFrames = try videoTrack.map { try Self.sampleCount(of: $0, in: asset) } ?? 0
        let sourcePackets = try audioTrack.map { try Self.sampleCount(of: $0, in: asset) } ?? 0

        var counts = Counts()
        if let videoTrack, sourceFrames > 0 {
            counts = try await writeBlurred(asset: asset, video: videoTrack, audio: sourcePackets > 0 ? audioTrack : nil,
                                            sourceFrames: sourceFrames, output: output, progress: progress)
        }
        // Frames the decoder never delivered are not in the output either: they are dropped too.
        let dropped = max(counts.refused, sourceFrames - counts.written)

        if counts.written == 0 {
            // No picture could be kept. What was written holds none, and is not kept as it is.
            try? FileManager.default.removeItem(at: output)
            guard let audioTrack, sourcePackets > 0 else {
                return BlurredPart.Report(framesWritten: 0, framesDropped: dropped, keptSound: false)
            }
            let packets = try await writeSoundOnly(asset: asset, audio: audioTrack, output: output)
            try await check(output, frames: 0, packets: packets, sourcePackets: sourcePackets)
            return BlurredPart.Report(framesWritten: 0, framesDropped: dropped, keptSound: true)
        }

        try await check(output, frames: counts.written, packets: counts.packets, sourcePackets: sourcePackets)
        return BlurredPart.Report(framesWritten: counts.written, framesDropped: dropped,
                                  droppedRuns: counts.runs, keptSound: counts.packets > 0)
    }

    private struct Counts {
        var written: Int64 = 0
        var refused: Int64 = 0
        var packets: Int64 = 0
        var runs: [BlurredPart.Report.Run] = []
    }

    /// Decodes every frame, puts it through the filter, and encodes what the filter returns,
    /// carrying the sound's packets across beside it.
    private func writeBlurred(asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack?, sourceFrames: Int64,
                              output: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> Counts {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable }
        let frames = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        frames.alwaysCopiesSampleData = false
        guard reader.canAdd(frames) else { throw Failure.unreadable }
        reader.add(frames)
        var sound: AVAssetReaderTrackOutput?
        if let audio {
            let passthrough = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            passthrough.alwaysCopiesSampleData = false
            guard reader.canAdd(passthrough) else { throw Failure.unreadable }
            reader.add(passthrough)
            sound = passthrough
        }

        let formats: [CMFormatDescription]
        let nominalRate: Float
        let transform: CGAffineTransform
        let naturalSize: CGSize
        let soundFormat: CMFormatDescription?
        let videoRange: CMTimeRange
        do {
            videoRange = try await video.load(.timeRange)
            formats = try await video.load(.formatDescriptions)
            nominalRate = try await video.load(.nominalFrameRate)
            transform = try await video.load(.preferredTransform)
            naturalSize = try await video.load(.naturalSize)
            soundFormat = try await audio?.load(.formatDescriptions).first
        } catch {
            throw Failure.unreadable
        }
        let dimensions = formats.first.map(CMVideoFormatDescriptionGetDimensions)
        let width = Int(dimensions?.width ?? Int32(naturalSize.width))
        let height = Int(dimensions?.height ?? Int32(naturalSize.height))
        guard width >= 2, height >= 2 else { throw Failure.unreadable }
        let frameRate = nominalRate.isFinite && nominalRate >= 1 ? Double(nominalRate) : 24

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mp4) } catch { throw Failure.couldNotWrite }
        // As the recorder encodes: H.264, at the rate the same picture is recorded at.
        let pictures = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoBitratePolicy.bitrate(width: width, height: height,
                                                                     frameRate: frameRate, profile: .disk),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        pictures.expectsMediaDataInRealTime = false
        pictures.transform = transform
        guard writer.canAdd(pictures) else { throw Failure.couldNotWrite }
        writer.add(pictures)
        var soundInput: AVAssetWriterInput?
        if sound != nil {
            // No settings: the packets are written as they were read.
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: soundFormat)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw Failure.couldNotWrite }
            writer.add(input)
            soundInput = input
        }

        guard reader.startReading() else { throw Failure.unreadable }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.couldNotWrite
        }
        writer.startSession(atSourceTime: .zero)

        var counts = Counts()
        do {
            guard let pool = Self.pixelBufferPool(width: width, height: height) else { throw Failure.couldNotWrite }
            var nextFrame = frames.copyNextSampleBuffer()
            var nextPackets = sound?.copyNextSampleBuffer()
            var picturesDone = false
            var soundDone = soundInput == nil
            /// The first frame's time: a run of dropped frames is told from here.
            var origin: CMTime?
            var runStart: CMTime?
            var lastEnd = CMTime.zero
            var seen: Int64 = 0

            while !picturesDone || !soundDone {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw Failure.couldNotWrite }
                var moved = false

                if !soundDone, let soundInput, soundInput.isReadyForMoreMediaData {
                    if let packets = nextPackets {
                        guard soundInput.append(packets) else { throw Failure.couldNotWrite }
                        counts.packets += Int64(CMSampleBufferGetNumSamples(packets))
                        nextPackets = sound?.copyNextSampleBuffer()
                    } else {
                        soundInput.markAsFinished()
                        soundDone = true
                    }
                    moved = true
                }

                if !picturesDone, pictures.isReadyForMoreMediaData {
                    if let sample = nextFrame {
                        nextFrame = frames.copyNextSampleBuffer()
                        // A buffer with no sample in it is a marker, not a frame.
                        if CMSampleBufferGetNumSamples(sample) > 0 {
                            let time = CMSampleBufferGetPresentationTimeStamp(sample)
                            let length = CMSampleBufferGetDuration(sample)
                            if origin == nil { origin = time }
                            if length.isNumeric { lastEnd = CMTimeMaximum(lastEnd, CMTimeAdd(time, length)) }
                            lastEnd = CMTimeMaximum(lastEnd, time)
                            seen += 1
                            let fraction = Double(seen) / Double(max(sourceFrames, 1))
                            let report = seen % 12 == 0

                            var blurred: CVPixelBuffer?
                            if let decoded = CMSampleBufferGetImageBuffer(sample), let image = Self.image(from: decoded) {
                                let filter = self.filter
                                let answer: Answer = await MainActor.run {
                                    if report { progress(fraction) }
                                    guard filter.isAvailable() else { return .unavailable }
                                    if let filtered = filter.apply(image) { return .blurred(filtered) }
                                    // Refused because this picture could not be processed, or
                                    // because the blur has stopped running?
                                    return filter.isAvailable() ? .refused : .unavailable
                                }
                                switch answer {
                                case .unavailable:
                                    throw Failure.interrupted
                                case .refused:
                                    break
                                case .blurred(let filtered):
                                    // Only what the filter returned is drawn, and only at the
                                    // size the part is: anything else is not a picture of this part.
                                    if let returned = filtered.cgImage, returned.width == width, returned.height == height {
                                        blurred = Self.pixelBuffer(drawing: returned, from: pool)
                                    }
                                }
                            }

                            if let blurred {
                                guard let encoded = Self.sample(blurred, at: time, lasting: length),
                                      pictures.append(encoded) else { throw Failure.couldNotWrite }
                                counts.written += 1
                                if let began = runStart, let origin {
                                    counts.runs.append(.init(from: CMTimeGetSeconds(CMTimeSubtract(began, origin)),
                                                             to: CMTimeGetSeconds(CMTimeSubtract(time, origin))))
                                    runStart = nil
                                }
                            } else {
                                counts.refused += 1
                                if runStart == nil { runStart = time }
                            }
                        }
                    } else {
                        pictures.markAsFinished()
                        picturesDone = true
                    }
                    moved = true
                }

                if !moved { try await Task.sleep(nanoseconds: 2_000_000) }
            }
            if let began = runStart, let origin {
                // Dropped to the end: the run reaches to where the video ends, which the track
                // says when the last frame does not say how long it lasts.
                if videoRange.end.isNumeric { lastEnd = CMTimeMaximum(lastEnd, videoRange.end) }
                counts.runs.append(.init(from: CMTimeGetSeconds(CMTimeSubtract(began, origin)),
                                         to: CMTimeGetSeconds(CMTimeSubtract(lastEnd, origin))))
            }
            // The whole of the recorded part must have been read: a reader that failed part-way
            // would otherwise leave a short file standing in for the part.
            guard reader.status == .completed else { throw Failure.unreadable }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.couldNotWrite }
        return counts
    }

    /// Writes the part's sound and nothing else: what is kept of a part none of whose pictures
    /// could be blurred.
    private func writeSoundOnly(asset: AVAsset, audio: AVAssetTrack, output: URL) async throws -> Int64 {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable }
        let sound = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
        sound.alwaysCopiesSampleData = false
        guard reader.canAdd(sound) else { throw Failure.unreadable }
        reader.add(sound)
        let format = try? await audio.load(.formatDescriptions).first

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: .mp4) } catch { throw Failure.couldNotWrite }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.couldNotWrite }
        writer.add(input)
        guard reader.startReading() else { throw Failure.unreadable }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw Failure.couldNotWrite
        }
        writer.startSession(atSourceTime: .zero)

        var written: Int64 = 0
        do {
            var next = sound.copyNextSampleBuffer()
            while let packets = next {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw Failure.couldNotWrite }
                guard input.isReadyForMoreMediaData else {
                    try await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                guard input.append(packets) else { throw Failure.couldNotWrite }
                written += Int64(CMSampleBufferGetNumSamples(packets))
                next = sound.copyNextSampleBuffer()
            }
            guard reader.status == .completed else { throw Failure.unreadable }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.couldNotWrite }
        return written
    }

    // MARK: - Checking what was made

    /// Reads the output back: it holds exactly the pictures that were encoded and exactly the
    /// packets of sound the recorded part held, and the system says it plays.
    private func check(_ output: URL, frames: Int64, packets: Int64, sourcePackets: Int64) async throws {
        guard packets == sourcePackets, Self.size(of: output) > 0 else { throw Failure.didNotCheckOut }
        let asset = AVURLAsset(url: output)
        do {
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard video.count == (frames > 0 ? 1 : 0), audio.count == (packets > 0 ? 1 : 0) else {
                throw Failure.didNotCheckOut
            }
            if let track = video.first {
                guard try Self.sampleCount(of: track, in: asset) == frames else { throw Failure.didNotCheckOut }
            }
            if let track = audio.first {
                guard try Self.sampleCount(of: track, in: asset) == packets else { throw Failure.didNotCheckOut }
            }
            guard try await asset.load(.isPlayable) else { throw Failure.didNotCheckOut }
        } catch {
            throw Failure.didNotCheckOut
        }
    }

    /// How many samples a track holds, read without decoding any of them.
    static func sampleCount(of track: AVAssetTrack, in asset: AVAsset) throws -> Int64 {
        guard let reader = try? AVAssetReader(asset: asset) else { throw Failure.unreadable }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable }
        var count: Int64 = 0
        while let buffer = output.copyNextSampleBuffer() {
            count += Int64(CMSampleBufferGetNumSamples(buffer))
        }
        guard reader.status == .completed else { throw Failure.unreadable }
        return count
    }

    // MARK: - Pixels

    /// A decoded frame as an image that owns its own bytes, so nothing the filter is handed can
    /// change underneath it.
    static func image(from buffer: CVPixelBuffer) -> UIImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { return nil }
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: image)
    }

    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func pixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ] as CFDictionary, &pool)
        return pool
    }

    /// A new pixel buffer holding exactly this image.
    static func pixelBuffer(drawing image: CGImage, from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo) else { return nil }
        // Copied, not blended: nothing of whatever the pool's buffer held before shows through.
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// The frame as a sample at the time, and for the length, it had in the recorded part.
    static func sample(_ buffer: CVPixelBuffer, at time: CMTime, lasting length: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: length, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    // MARK: - Small things

    static func size(of file: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func volumeFreeBytes(_ folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

extension BundleBlurPass {
    /// The pass over the app's own face blur: the one chokepoint every still goes through, under
    /// the scope that is filtered whatever the app-wide blur switch says
    /// (`PrivacyFilterScope.officeRecordingBlur`). There is no other way a picture is blurred here.
    @MainActor
    static func app(filter: any StillImageFiltering, isAvailable: @escaping @MainActor () -> Bool) -> BundleBlurPass {
        BundleBlurPass(filter: Filter(
            isAvailable: isAvailable,
            apply: { image in filter.filteredOrUnavailable(image, for: .officeRecordingBlur) }))
    }
}
