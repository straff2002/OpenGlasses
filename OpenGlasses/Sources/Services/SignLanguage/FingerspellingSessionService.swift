import Combine
import Foundation
import QuartzCore
import UIKit

/// Live fingerspelling session (Plan CK activation surface): glasses camera frames →
/// `HolisticLandmarkProviding` → `FingerspellingLiveDecoder` → provisional words on the
/// HUD, committed words spoken. Follows the `AssistiveModeService` shape — `@MainActor`
/// singleton, dependencies injected on `start` so the service never retains AppState's
/// services — with the heavy work (landmark extraction + Core ML decode) on a dedicated
/// actor fed by an ordered, frame-dropping stream.
///
/// The core `start(dependencies:)` seam takes protocol/closure dependencies only, so unit
/// tests drive a full session with synthetic frames and never touch MediaPipe, Core ML,
/// `CameraService`, or `Wearables`.
@MainActor
final class FingerspellingSessionService: ObservableObject {
    static let shared = FingerspellingSessionService()

    /// Everything the session needs, as seams. `speak`/`showCaption`/`clearCaption`
    /// isolate the TTS + HUD surfaces; `inference` runs inside the pipeline actor.
    struct Dependencies {
        var landmarks: HolisticLandmarkProviding
        var inference: FingerspellingLiveDecoder.Inference
        var speak: (String) async -> Void
        var showCaption: (String) -> Void
        var clearCaption: () -> Void
    }

    @Published private(set) var isActive = false
    /// The uncommitted word currently forming (mirrors the HUD caption).
    @Published private(set) var provisionalWord = ""
    /// The most recently committed (spoken) word.
    @Published private(set) var lastCommittedWord: String?
    /// User-facing status/problem line ("Model not downloaded", extraction errors, …).
    @Published private(set) var statusDetail: String?

    private var frameContinuation: AsyncStream<(UIImage, Int)>.Continuation?
    private var pump: Task<Void, Never>?
    private var frameSubscription: AnyCancellable?
    private weak var camera: CameraService?
    /// Whether this session started the camera stream (and so should stop it).
    private var ownsCameraStream = false
    private var lastTimestampMs = 0
    private var dependencies: Dependencies?

    /// Internal (not private) so tests can run fresh instances; production code uses
    /// `.shared`.
    init() {}

    // MARK: - Core lifecycle (test seam)

    /// Start with explicit dependencies. `decodeEveryFrames` sets the decode cadence in
    /// appended frames (≈ every half second at 15 fps with the default; P3 tunes this).
    /// `frameBufferLimit` bounds the hand-off queue — a slow decode drops frames instead
    /// of building latency; tests pass nil (unbounded) so synchronous bursts all arrive.
    func start(dependencies: Dependencies,
               decodeEveryFrames: Int = 8,
               frameBufferLimit: Int? = 2) {
        guard !isActive else { return }
        isActive = true
        statusDetail = nil
        provisionalWord = ""
        lastCommittedWord = nil
        lastTimestampMs = 0
        self.dependencies = dependencies

        // Ordered hand-off to the pipeline: one consumer task, newest-frames-win buffering.
        let (stream, continuation) = AsyncStream.makeStream(
            of: (UIImage, Int).self,
            bufferingPolicy: frameBufferLimit.map { .bufferingNewest($0) } ?? .unbounded)
        frameContinuation = continuation
        let pipeline = FingerspellingPipeline(landmarks: dependencies.landmarks,
                                              inference: dependencies.inference,
                                              decodeEveryFrames: decodeEveryFrames)
        pump = Task { [weak self] in
            for await (image, timestamp) in stream {
                let outcome = await pipeline.process(image: image,
                                                     timestampMilliseconds: timestamp)
                await self?.apply(outcome)
            }
            let finale = await pipeline.flush()
            await self?.apply(finale)
            await self?.finishStopped()
        }
    }

    /// Feed one camera frame (main-actor; hops to the pipeline).
    func ingest(image: UIImage) {
        guard isActive else { return }
        // Monotonic, strictly increasing timestamps (video running-mode requirement).
        let now = Int(CACurrentMediaTime() * 1000)
        lastTimestampMs = max(now, lastTimestampMs + 1)
        frameContinuation?.yield((image, lastTimestampMs))
    }

    /// Stop the session; the pending word (if any) is flushed and spoken on the way out.
    func stop() {
        guard isActive else { return }
        isActive = false
        frameSubscription = nil
        frameContinuation?.finish()
        frameContinuation = nil
        if ownsCameraStream, let camera {
            ownsCameraStream = false
            Task { await camera.stopStreaming() }
        }
        camera = nil
    }

    // MARK: - Live wiring

    /// Production entry: builds the MediaPipe + Core ML dependencies from the downloaded
    /// model bundle, subscribes to the camera, and ensures the stream is running.
    func startLive(camera: CameraService,
                   tts: TextToSpeechService,
                   display: GlassesDisplayService) async {
        guard !isActive else { return }
        guard Config.fingerspellingEnabled else {
            statusDetail = "Fingerspelling is disabled in Settings."
            return
        }
        let store = FingerspellingModelStore()
        guard store.isModelPresent else {
            statusDetail = store.bundle.isConfigured
                ? "Model not downloaded yet." : "No model repository configured."
            return
        }

        let landmarkerURL = store.fileURL(FingerspellingModelBundle.landmarkerTaskName)
        let modelURL = store.fileURL(FingerspellingModelBundle.modelPackageName)
        let built: (HolisticLandmarkService, FingerspellingInferenceEngine)
        do {
            // Heavy: MediaPipe graph init + first-run Core ML compile. Off the main actor.
            built = try await Task.detached(priority: .userInitiated) {
                (try HolisticLandmarkService(taskModelURL: landmarkerURL),
                 try FingerspellingInferenceEngine(modelPackageURL: modelURL))
            }.value
        } catch {
            statusDetail = "Couldn't start recognizer: \(error.localizedDescription)"
            return
        }

        start(dependencies: Dependencies(
            landmarks: built.0,
            inference: built.1.logits(for:),
            speak: { [weak tts] word in
                await tts?.speak(word, mirrorToHUD: false)
            },
            showCaption: { [weak display] text in
                display?.showText(text, flashWhileInteractive: true)
            },
            clearCaption: { [weak display] in
                display?.clear()
            }))

        self.camera = camera
        frameSubscription = camera.framePublisher.sink { [weak self] image in
            self?.ingest(image: image)
        }
        if !camera.isStreaming {
            do {
                try await camera.startStreaming()
                ownsCameraStream = true
            } catch {
                statusDetail = "Camera unavailable: \(error.localizedDescription)"
                stop()
            }
        }
    }

    // MARK: - Event routing

    private func apply(_ outcome: FingerspellingPipeline.Outcome) async {
        guard let dependencies else { return }
        if let problem = outcome.problem {
            statusDetail = problem
        }
        for event in outcome.events {
            switch event {
            case .none:
                break
            case .display(let word):
                provisionalWord = word
                dependencies.showCaption(word)
            case .commit(let word):
                provisionalWord = ""
                lastCommittedWord = word
                dependencies.showCaption(word)
                await dependencies.speak(word)
            case .rejected:
                provisionalWord = ""
            }
        }
    }

    /// Runs after the pump drains (post-`stop()` flush): clear the HUD and stream state.
    private func finishStopped() {
        dependencies?.clearCaption()
        dependencies = nil
        pump = nil
        provisionalWord = ""
    }
}

/// Off-main pipeline: serialises landmark extraction, window building, and Core ML decode
/// for one session. Pure per-call — all streaming state lives in the decoder value.
actor FingerspellingPipeline {
    struct Outcome {
        var events: [DecodeStabilityPolicy.Event] = []
        var problem: String?
    }

    private let landmarks: HolisticLandmarkProviding
    private let inference: FingerspellingLiveDecoder.Inference
    private let decodeEveryFrames: Int
    private var decoder: FingerspellingLiveDecoder
    private var framesSinceDecode = 0

    init(landmarks: HolisticLandmarkProviding,
         inference: @escaping FingerspellingLiveDecoder.Inference,
         decodeEveryFrames: Int,
         rules: DecodeStabilityPolicy.Rules = FingerspellingLiveDecoder.ctcRules()) {
        self.landmarks = landmarks
        self.inference = inference
        self.decodeEveryFrames = max(decodeEveryFrames, 1)
        self.decoder = FingerspellingLiveDecoder(rules: rules)
    }

    func process(image: UIImage, timestampMilliseconds: Int) -> Outcome {
        var outcome = Outcome()
        let frame: HolisticFrame
        do {
            frame = try landmarks.holisticFrame(for: image,
                                                timestampMilliseconds: timestampMilliseconds)
        } catch {
            outcome.problem = "Landmark extraction failed: \(error.localizedDescription)"
            return outcome
        }
        outcome.events = decoder.append(frame)

        framesSinceDecode += 1
        guard framesSinceDecode >= decodeEveryFrames,
              decoder.windowedFrameCount > 0 else { return outcome }
        framesSinceDecode = 0
        do {
            outcome.events += try decoder.tick(infer: inference)
        } catch {
            outcome.problem = "Decode failed: \(error.localizedDescription)"
        }
        return outcome
    }

    func flush() -> Outcome {
        let event = decoder.flush()
        return Outcome(events: event == .none ? [] : [event])
    }
}
