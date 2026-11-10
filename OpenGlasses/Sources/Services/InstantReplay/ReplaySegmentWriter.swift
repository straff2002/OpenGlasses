import AVFoundation
import UIKit

/// What turns relay frames into one buffer segment. A protocol so the buffer's behaviour —
/// rotation, eviction, every stop condition — is testable without an encoder deciding the result.
@MainActor
protocol ReplaySegmentWriting: AnyObject {
    /// Append one frame `seconds` after the segment started. Never blocks the caller on encoding.
    func append(_ image: UIImage, at seconds: TimeInterval)
    /// Finish the file. False when the writer failed, in which case the segment is dropped.
    func finish() async -> Bool
    /// Abandon the file.
    func cancel()
}

/// What joins segments into one clip and makes its poster frame.
protocol ReplayClipComposing: Sendable {
    /// Join `segments`, in order, into one MP4 at `output` with **no re-encode**, and return its
    /// length in seconds.
    func compose(_ segments: [URL], to output: URL) async throws -> TimeInterval
    /// A JPEG of the clip's first frame, for a job's evidence list. Nil when it can't be made.
    func posterJPEG(of url: URL) async -> Data?
}

/// One segment, H.264 in an MP4, video only, starting on a keyframe — the same encoder settings
/// the long-form recorder and job clips use (`VideoBitratePolicy`'s disk profile at the size and
/// rate the relay delivers).
///
/// One writer per segment (rather than one writer cutting fragmented segments): every segment is
/// then an ordinary, self-contained MP4 that opens on its own, starts on a keyframe by
/// construction, and survives the writer after it failing. The encode itself runs on this
/// writer's own serial queue, so the main actor only hands frames over.
@MainActor
final class AVReplaySegmentWriter: ReplaySegmentWriting {

    private let core: Core

    init(url: URL, size: CGSize, frameRate: Int) throws {
        core = try Core(url: url, size: size, frameRate: frameRate)
    }

    func append(_ image: UIImage, at seconds: TimeInterval) {
        guard let cgImage = image.cgImage else { return }
        core.append(cgImage, at: seconds)
    }

    func finish() async -> Bool { await core.finish() }

    func cancel() { core.cancel() }

    enum WriterError: Error { case couldNotStart }

    /// Everything `AVAssetWriter` touches, confined to one serial queue.
    private final class Core: @unchecked Sendable {
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let size: CGSize
        private let queue = DispatchQueue(label: "com.openglasses.replay.segment", qos: .utility)
        private var open = true
        private var lastTime: TimeInterval = -1

        init(url: URL, size: CGSize, frameRate: Int) throws {
            self.size = size
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let bitrate = VideoBitratePolicy.bitrate(width: Int(size.width), height: Int(size.height),
                                                     frameRate: Double(frameRate), profile: .disk)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: frameRate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: ReplayBufferPlan.segmentSeconds,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ]
            input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? WriterError.couldNotStart }
            writer.startSession(atSourceTime: .zero)
        }

        func append(_ cgImage: CGImage, at seconds: TimeInterval) {
            queue.async { [self] in
                // A frame that would not move the clock forward is dropped: the encoder refuses
                // a presentation time that does not increase.
                guard open, writer.status == .writing, input.isReadyForMoreMediaData,
                      seconds > lastTime else { return }
                var buffer: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
                }
                if buffer == nil {
                    CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                        kCVPixelFormatType_32BGRA, nil, &buffer)
                }
                guard let pixelBuffer = buffer else { return }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let drawn: Bool = {
                    guard let context = CGContext(
                        data: CVPixelBufferGetBaseAddress(pixelBuffer),
                        width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                    context.draw(cgImage, in: CGRect(origin: .zero, size: size))
                    return true
                }()
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard drawn else { return }
                if adaptor.append(pixelBuffer,
                                  withPresentationTime: CMTime(seconds: max(0, seconds),
                                                               preferredTimescale: 600)) {
                    lastTime = seconds
                }
            }
        }

        func finish() async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                queue.async { [self] in
                    guard open, writer.status == .writing else {
                        open = false
                        continuation.resume(returning: false)
                        return
                    }
                    open = false
                    input.markAsFinished()
                    writer.finishWriting { [writer] in
                        continuation.resume(returning: writer.status == .completed)
                    }
                }
            }
        }

        func cancel() {
            queue.async { [self] in
                guard open else { return }
                open = false
                writer.cancelWriting()
            }
        }
    }
}

/// The real composer: an `AVMutableComposition` over the segment files, exported passthrough.
struct AVReplayClipComposer: ReplayClipComposing {

    enum ComposeError: Error { case noVideo, couldNotExport }

    func compose(_ segments: [URL], to output: URL) async throws -> TimeInterval {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposeError.noVideo
        }
        var cursor = CMTime.zero
        var transformSet = false
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await source.load(.timeRange)
            guard range.duration > .zero else { continue }
            try track.insertTimeRange(range, of: source, at: cursor)
            if !transformSet {
                track.preferredTransform = try await source.load(.preferredTransform)
                transformSet = true
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw ComposeError.noVideo }
        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetPassthrough) else {
            throw ComposeError.couldNotExport
        }
        try await exporter.export(to: output, as: .mp4)
        return cursor.seconds
    }

    func posterJPEG(of url: URL) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }
}
