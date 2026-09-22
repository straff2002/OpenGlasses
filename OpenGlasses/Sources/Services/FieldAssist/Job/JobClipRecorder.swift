import AVFoundation
import Combine
import Foundation
import UIKit

/// A short, length-capped clip of the job, recorded off the blurred frame relay (Plan FO P2b).
///
/// # Why this is not `VideoRecordingService`
///
/// That service records for as long as the wearer wants, muxes microphone audio, files the result
/// into Documents/Recordings and writes it to the Photos library. Every one of those is wrong here.
/// A clip is evidence: it belongs under the session like a photograph, it is capped so a technician
/// cannot accidentally attach nine minutes of walking to a work order, and it is **silent** —
/// see below. Sharing the long-form recorder would have meant bending all four of those, and the
/// one property both of them must have, the frame source, is the one this takes as a parameter.
///
/// # Where the pixels come from
///
/// `OutboundFrameRelay.publisher`, like every other camera-rate consumer, and never
/// `CameraService.framePublisher`. The relay is where the bystander blur happens, once, for
/// everybody downstream; a recorder that read the raw publisher would write unblurred faces into a
/// file that is then attached to a customer's work order, which is precisely the failure the roster
/// (`OutboundFrameConsumer.jobClipRecording`) exists to make impossible to add quietly. The
/// publisher arrives as an argument rather than being fetched, so this type never has to know that
/// `CameraService` exists.
///
/// # Audio: off, deliberately
///
/// v1 records **video only**. `VideoRecordingService` does capture microphone audio through
/// `CaptureAudioRouter`, so the machinery exists — but the policy around it does not transfer. That
/// recorder's audio is something the wearer starts, is told about and stops; a job clip is started
/// by a sentence in the middle of a service visit, in a customer's plant room, with a customer very
/// likely standing in it. Recording bystander speech onto a file that is then attached to a report
/// is a consent question this plan has not asked, it has no equivalent of the face blur to fall
/// back on, and in medical/HIPAA mode it would put a third party's voice into a compliance record
/// nobody can delete. So the clip is silent until a pilot asks otherwise, and the refusal is here
/// in the open rather than as an unset flag.
@MainActor
final class JobClipRecorder: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isRecording = false
    /// The clip being recorded right now, for the button's countdown.
    @Published private(set) var elapsed: TimeInterval = 0
    /// The cap this clip is running against, so the countdown has something to count towards.
    @Published private(set) var capSeconds: TimeInterval = JobClipRecorder.defaultCapSeconds
    /// The caption the technician gave when they asked for it, if any.
    @Published private(set) var caption: String?

    /// Seconds left before the cap stops it. Zero once it has.
    var remainingSeconds: TimeInterval { max(0, capSeconds - elapsed) }

    /// "0:12 of 0:30" — what the record button shows while it runs.
    var countdownLabel: String {
        Self.clock(elapsed) + " of " + Self.clock(capSeconds)
    }

    /// `nonisolated` because the two nested value types below format their own spoken lines, and
    /// those are plain values a caller may read from anywhere.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Caps

    /// The length a clip runs for when nobody says otherwise.
    ///
    /// Thirty seconds is long enough to show a fault behaving — a compressor short-cycling, a fan
    /// wobbling, a flame lifting — and short enough that the file is small enough to email. It is a
    /// `Config` value because Plan FO's open question asks a pilot device to confirm it.
    static var defaultCapSeconds: TimeInterval { Config.jobClipDefaultSeconds }
    /// The longest a clip may be asked for. Past this a technician wants the long-form recorder,
    /// which has no limit and files its output somewhere a work order never goes.
    static var maximumCapSeconds: TimeInterval { Config.jobClipMaximumSeconds }

    /// Seconds without a frame before a running clip is treated as a dead stream, finished with
    /// what it has, and labelled cut short. Shorter than the long-form recorder's fifteen because
    /// the whole clip is only thirty: waiting half of it to notice the glasses died would produce a
    /// file that is mostly nothing.
    ///
    /// `nonisolated` for the same reason `VideoRecordingService.frameStallSeconds` is — it is the
    /// default argument of the pure stall decision below, and a default argument is evaluated
    /// outside the actor.
    nonisolated static let stallSeconds: TimeInterval = 4

    // MARK: - Seams

    /// Everything device-facing, injected, so the whole path — refusals, cap, stall, poster frame,
    /// what lands on the session — is exercisable with no camera, no writer and no glasses.
    struct Seams {
        /// Where the clip is filed. The same service photographs go to, for the same reason: a
        /// clip is evidence of the visit and belongs under the visit's own store.
        var sessions: () -> any JobClipFiling = { FieldSessionService.shared }
        /// Is the camera producing pictures right now? A clip recorded off a stalled stream is
        /// thirty seconds of the last frame, which is worse than an honest refusal.
        var readiness: () -> CameraReadiness? = { nil }
        /// The app-wide face-blur setting, recorded against the clip exactly as a photo's is.
        var filterEnabled: () -> Bool = { Config.privacyFilterEnabled }
        /// Builds the thing that turns frames into a file. Injected so a test can assert what was
        /// appended and when it was finished without an `AVAssetWriter`.
        var makeWriter: @MainActor (URL, CGSize) throws -> any ClipWriting = { url, size in
            try AVAssetClipWriter(url: url, size: size)
        }
        /// Monotonic-ish clock. Frame timing and the cap are the whole behaviour, so a test has to
        /// be able to make time pass without sleeping.
        var now: () -> Date = { Date() }
        /// Where the file is written before it is filed. Defaults to the system temporary
        /// directory; the session's own store is where it ends up.
        var scratchDirectory: () -> URL = { FileManager.default.temporaryDirectory }
    }

    private var seams: Seams

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Wire the app's services in after construction, the way `JobPhotoEvidenceService` is.
    func connect(_ seams: Seams) { self.seams = seams }

    // MARK: - Starting

    /// Why a clip could not be started. Every case is a sentence the technician hears, because the
    /// alternative — a silent no-op, or a black thirty-second file — is the failure this refuses.
    enum StartRefusal: Error, Equatable {
        case noOpenJob
        case alreadyRecording(elapsed: TimeInterval)
        case cameraNotReady(String)
        case couldNotWrite

        var spoken: String {
            switch self {
            case .noOpenJob:
                return "There's no job open, so there's nowhere to put a clip. Start a job first."
            case .alreadyRecording(let elapsed):
                return "Already recording a clip — \(JobClipRecorder.clock(elapsed)) so far. "
                    + "Say stop the clip when you're done."
            case .cameraNotReady(let phrase):
                return "\(phrase), so there's nothing to record. Check the glasses are on and "
                    + "streaming, then try again."
            case .couldNotWrite:
                return "The clip couldn't be started — the video file could not be created."
            }
        }
    }

    /// A clip that finished, however it finished.
    struct Finished: Equatable {
        let itemId: String
        let duration: TimeInterval
        let byteCount: Int
        let cutShort: Bool
        /// Why it ended, for the sentence the technician hears.
        let ending: Ending

        enum Ending: Equatable {
            case asked
            case reachedCap
            case streamStopped
            case jobClosed
        }

        var spoken: String {
            let length = JobClipRecorder.clock(duration)
            switch ending {
            case .asked: return "Clip saved — \(length)."
            case .reachedCap:
                return "That's the \(JobClipRecorder.clock(duration)) limit — clip saved."
            case .streamStopped:
                return "The glasses stopped sending video, so I've saved the \(length) captured "
                    + "so far. It's marked as cut short."
            case .jobClosed:
                return "The job closed, so the clip was saved at \(length) and marked as cut short."
            }
        }
    }

    /// Start recording, or say why not.
    ///
    /// - Parameters:
    ///   - publisher: the **blurred** relay. Never `CameraService.framePublisher` — see the type's
    ///     own documentation, and `OutboundFrameConsumerTests`, which asserts it from the source.
    ///   - seconds: how long the technician asked for, clamped into `1...maximumCapSeconds`.
    func start(from publisher: PassthroughSubject<UIImage, Never>,
               caption: String? = nil,
               seconds: TimeInterval? = nil) -> Result<TimeInterval, StartRefusal> {
        guard !isRecording else { return .failure(.alreadyRecording(elapsed: elapsed)) }
        guard seams.sessions().isOpenForEvidence else { return .failure(.noOpenJob) }

        // The camera has to be producing pictures *now*. `hasFreshVisualEvidence` is the same
        // question every other see-something action asks, and it is two facts rather than one: the
        // phase is ready **and** the newest decoded frame is recent. A stale-but-present frame is
        // exactly how a "clip" ends up being a still held for thirty seconds.
        let readiness = seams.readiness()
        guard let readiness else { return .failure(.cameraNotReady("The camera isn't running")) }
        guard readiness.hasFreshVisualEvidence else {
            return .failure(.cameraNotReady(readiness.statusPhrase))
        }

        let cap = Self.cap(forRequested: seconds)
        let url = seams.scratchDirectory()
            .appendingPathComponent("job-clip-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        self.pendingURL = url
        self.capSeconds = cap
        self.caption = caption
        self.elapsed = 0
        self.startedAt = seams.now()
        self.lastFrameAt = nil
        self.writer = nil
        self.poster = nil
        self.frameCount = 0
        self.isRecording = true
        self.filterWasOnAtStart = seams.filterEnabled()

        subscription = publisher.sink { [weak self] image in
            self?.ingest(image)
        }
        // One tick a second: it drives the countdown, the cap and the stall watchdog, and a clip is
        // measured in seconds so nothing finer would be shown anyway.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        return .success(cap)
    }

    /// The cap a request resolves to: the default when nothing was asked for, and otherwise what
    /// was asked for held inside one second and the maximum. A request beyond the maximum is
    /// clamped rather than refused — the technician gets the longest clip there is, and is told.
    static func cap(forRequested seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds > 0 else { return defaultCapSeconds }
        return min(max(1, seconds.rounded()), maximumCapSeconds)
    }

    // MARK: - Stopping

    /// Stop and file the clip. Nil when nothing was recording, or when nothing could be written.
    @discardableResult
    func stop(ending: Finished.Ending = .asked) async -> Finished? {
        guard isRecording else { return nil }
        subscription?.cancel()
        subscription = nil
        ticker?.invalidate()
        ticker = nil
        isRecording = false

        let duration = elapsed
        let cutShort = ending != .asked
        let caption = self.caption
        let filterWasOn = filterWasOnAtStart
        let poster = self.poster
        self.caption = nil

        guard let writer, let url = pendingURL, frameCount > 0 else {
            // Nothing was ever written. Clean up rather than filing an empty file that a technician
            // would later find on a work order with nothing in it.
            pendingURL.map { try? FileManager.default.removeItem(at: $0) }
            self.writer = nil
            self.pendingURL = nil
            self.poster = nil
            return nil
        }
        let wrote = await writer.finish()
        self.writer = nil
        self.pendingURL = nil
        self.poster = nil
        guard wrote else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        guard !data.isEmpty else { return nil }

        let posterData = poster?.jpegData(compressionQuality: 0.85)
        guard let itemId = seams.sessions().attachClip(
            data, posterJPEG: posterData, caption: caption,
            durationSeconds: duration, filterWasOn: filterWasOn, cutShort: cutShort) else {
            return nil
        }
        return Finished(itemId: itemId, duration: duration, byteCount: data.count,
                        cutShort: cutShort, ending: ending)
    }

    // MARK: - The loop

    private var subscription: AnyCancellable?
    private var ticker: Timer?
    private var writer: (any ClipWriting)?
    private var pendingURL: URL?
    private var startedAt: Date?
    private var lastFrameAt: Date?
    private var poster: UIImage?
    private var frameCount = 0
    private var filterWasOnAtStart = false

    private func ingest(_ image: UIImage) {
        guard isRecording, let startedAt else { return }
        let now = seams.now()
        lastFrameAt = now
        // The first frame off the relay is the poster: it has already been through the blur, it is
        // certainly decodable because it is a `UIImage`, and it exists at capture rather than
        // depending on a video decode of a file that may be the very thing that went wrong.
        if poster == nil { poster = image }

        if writer == nil {
            guard let url = pendingURL, let size = Self.encodeSize(of: image) else { return }
            guard let made = try? seams.makeWriter(url, size) else {
                // A writer that cannot be made is not something the next frame will fix. Stop,
                // rather than spending the cap failing once a frame.
                Task { @MainActor in await self.abandon() }
                return
            }
            writer = made
        }
        guard let writer else { return }
        writer.append(image, at: now.timeIntervalSince(startedAt))
        frameCount += 1
    }

    /// One second of wall clock: move the countdown, stop at the cap, and notice a dead stream.
    ///
    /// Not private: the cap, the stall and the job-closing rules are the whole behaviour, and a
    /// test that had to wait a real second per assertion would be a test nobody runs. It is driven
    /// by the ticker in the app and by an injected clock in the suite.
    func tick() async {
        guard isRecording, let startedAt else { return }
        elapsed = seams.now().timeIntervalSince(startedAt)
        // The job going away underneath a running clip is checked here rather than hooked onto
        // each of the four ways a job can close (the tool, the Job tab, Settings, the guided
        // flow). One question asked once a second covers all of them, and it is the same question
        // every other evidence route asks before it writes anything.
        if !seams.sessions().isOpenForEvidence {
            let finished = await stop(ending: .jobClosed)
            onFinished?(finished)
            return
        }
        if elapsed >= capSeconds {
            let finished = await stop(ending: .reachedCap)
            onFinished?(finished)
            return
        }
        if Self.streamHasStopped(lastFrameAt: lastFrameAt, startedAt: startedAt,
                                 now: seams.now()) {
            let finished = await stop(ending: .streamStopped)
            onFinished?(finished)
        }
    }

    /// Pure stall decision, so the table is provable without a timer.
    ///
    /// A clip that has not seen its *first* frame is judged from when it started — unlike the
    /// long-form recorder, which leaves a never-started recording alone indefinitely. Thirty
    /// seconds is too short to spend waiting for a stream that is not coming, and the technician
    /// asked for a clip of something they can see.
    static func streamHasStopped(lastFrameAt: Date?, startedAt: Date, now: Date,
                                 stallSeconds: TimeInterval = JobClipRecorder.stallSeconds) -> Bool {
        now.timeIntervalSince(lastFrameAt ?? startedAt) >= stallSeconds
    }

    /// Give up without filing anything — the writer could not be created at all.
    private func abandon() async {
        subscription?.cancel()
        subscription = nil
        ticker?.invalidate()
        ticker = nil
        isRecording = false
        writer?.cancel()
        writer = nil
        pendingURL.map { try? FileManager.default.removeItem(at: $0) }
        pendingURL = nil
        poster = nil
        caption = nil
        onFinished?(nil)
    }

    /// Called when a clip ends on its own — the cap, or a dead stream — so the app can say so out
    /// loud. Not called for a stop the technician asked for; that one has a return value.
    var onFinished: ((Finished?) -> Void)?

    /// H.264 needs even dimensions, and the encoder needs the size the frames actually arrive in
    /// rather than a guess — a clip encoded at the wrong geometry is letterboxed evidence.
    static func encodeSize(of image: UIImage) -> CGSize? {
        guard let cgImage = image.cgImage else { return nil }
        let width = max(2, (cgImage.width / 2) * 2)
        let height = max(2, (cgImage.height / 2) * 2)
        return CGSize(width: width, height: height)
    }
}

/// What turns frames into a file. A protocol so the recorder's whole behaviour — the cap, the
/// stall, the poster, what lands on the session — is testable without `AVFoundation` deciding
/// whether a test passes.
@MainActor
protocol ClipWriting: AnyObject {
    func append(_ image: UIImage, at seconds: TimeInterval)
    /// Finish the file. False when the writer failed, in which case nothing is filed.
    func finish() async -> Bool
    func cancel()
}

/// Where a clip is filed. The counterpart of `JobEvidenceFiling`, which photographs use.
@MainActor
protocol JobClipFiling: AnyObject {
    /// Whether a job is open enough to take evidence. Paused counts.
    var isOpenForEvidence: Bool { get }
    /// File the clip and its poster frame under the session. Returns the catalogue id, which is the
    /// file's name — the same identity a photograph's is.
    @discardableResult
    func attachClip(_ data: Data, posterJPEG: Data?, caption: String?,
                    durationSeconds: TimeInterval, filterWasOn: Bool, cutShort: Bool) -> String?
}

extension FieldSessionService: JobClipFiling {}

/// The real writer: H.264 in an MP4, video only, at the size and rate the relay actually delivers.
@MainActor
final class AVAssetClipWriter: ClipWriting {

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var started = false

    init(url: URL, size: CGSize) throws {
        self.size = size
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = VideoBitratePolicy.bitrate(width: Int(size.width), height: Int(size.height),
                                                 frameRate: Double(Config.cameraFrameRate),
                                                 profile: .disk, override: nil)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Config.cameraFrameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ClipWriterError.couldNotStart }
        writer.startSession(atSourceTime: .zero)
        started = true
    }

    enum ClipWriterError: Error { case couldNotStart }

    func append(_ image: UIImage, at seconds: TimeInterval) {
        guard started, writer.status == .writing, input.isReadyForMoreMediaData,
              let cgImage = image.cgImage else { return }
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                  kCVPixelFormatType_32BGRA, attrs as CFDictionary,
                                  &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        adaptor.append(pixelBuffer,
                       withPresentationTime: CMTime(seconds: max(0, seconds),
                                                    preferredTimescale: 600))
    }

    func finish() async -> Bool {
        guard started else { return false }
        started = false
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        return writer.status == .completed
    }

    func cancel() {
        guard started else { return }
        started = false
        writer.cancelWriting()
    }
}
