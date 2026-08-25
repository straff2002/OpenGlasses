import Foundation
import AVFoundation
import Combine
import Photos
import UIKit

/// Records video + audio from a stream of UIImage frames and the shared audio engine.
///
/// Optimized for long-form recording (clinical interviews, meetings, etc.):
/// - No time limit — records until explicitly stopped
/// - Muxes glasses microphone audio into the MP4 alongside video
/// - Every finished recording is filed out of `tmp/` by `RecordingFiler`, whatever started it
/// - Efficient pixel buffer pooling to minimize allocations during long sessions
/// - Background audio session keeps the app alive in the pocket
@MainActor
class VideoRecordingService: ObservableObject {
    @Published var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0

    /// Where finished recordings are filed. Injectable so a caller (or a test) can point the
    /// recorder somewhere other than Documents/Recordings.
    var recordingsDirectory: URL = RecordingFiler.defaultRecordingsDirectory

    /// Set by `stopRecording` when a destination the user asked for did not land — a plain-words
    /// note naming where the recording actually is. Nil when everything went where it should.
    private(set) var lastSaveNote: String?

    /// Set by `stopRecording` to where the finished recording ended up, in plain words.
    private(set) var lastSaveSummary: String?

    /// When true, ambient captions are started alongside recording for live transcription.
    var autoTranscribe = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var durationTimer: Timer?
    private var recordingStartDate: Date?
    private var outputURL: URL?
    private var frameSubscription: AnyCancellable?

    // Accessed from background audio callback — must be nonisolated(unsafe)
    private nonisolated(unsafe) var audioInput: AVAssetWriterInput?

    /// ID used to register as an audio buffer consumer on WakeWordService.
    private static let audioConsumerId = "video_recording_audio"

    /// Reference to WakeWordService for audio buffer access.
    weak var wakeWordService: WakeWordService?

    /// Reference to AmbientCaptionService for auto-transcription.
    weak var ambientCaptionService: AmbientCaptionService?

    /// Reference to MeetingAssistantService for real-time meeting summaries.
    weak var meetingAssistant: MeetingAssistantService?

    /// LLM closure injected by AppState; forwarded to MeetingAssistantService when recording starts.
    var llmClosure: ((String) async throws -> String)?

    /// Reference to HIPAA service for file protection and audit logging.
    weak var hipaaService: HIPAAComplianceService?

    // These are accessed from the background recording queue
    private nonisolated(unsafe) var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private nonisolated(unsafe) var videoStartTime: CMTime?
    private nonisolated(unsafe) var audioStartTime: CMTime?
    private nonisolated(unsafe) var frameCount: Int64 = 0
    /// Reusable pixel buffer pool — avoids per-frame allocation during long recordings.
    private nonisolated(unsafe) var pixelBufferPool: CVPixelBufferPool?
    private nonisolated(unsafe) var poolWidth: Int = 0
    private nonisolated(unsafe) var poolHeight: Int = 0

    /// Name of the Photos album where recordings are saved.
    private nonisolated static let albumName = "Glasses"

    /// Transcript accumulated during recording (from ambient captions).
    @Published private(set) var recordingTranscript: String = ""
    private var transcriptEntries: [String] = []
    /// Position in the caption stream. Sequence-based, because `captionHistory` is capped and
    /// stops growing once full.
    private var captionCursor = CaptionCursor()

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let mins = (Int(recordingDuration) % 3600) / 60
        let secs = Int(recordingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Storage guard

    /// Recording refuses to start below this free-disk floor (a dying write corrupts the MP4).
    static let minimumFreeBytes: Int64 = 200 * 1_000_000
    /// Below this, recording still starts but the caller should warn with the estimated headroom.
    static let lowStorageBytes: Int64 = 2_000 * 1_000_000

    enum StorageVerdict: Equatable {
        case ok
        /// Enough to record, but low — carries the estimated minutes of recording left.
        case low(minutesRemaining: Int)
        case insufficient
    }

    /// Pure storage decision (testable): free bytes + the actual encode bitrates → verdict.
    static func storageVerdict(freeBytes: Int64, videoBitrate: Int, audioBitrate: Int = 64_000) -> StorageVerdict {
        if freeBytes < minimumFreeBytes { return .insufficient }
        guard freeBytes < lowStorageBytes else { return .ok }
        let bytesPerSecond = max(Double(videoBitrate + audioBitrate) / 8, 1)
        let minutes = Int(Double(freeBytes) / bytesPerSecond / 60)
        return .low(minutesRemaining: minutes)
    }

    /// Free disk space usable for a recording (importantUsage — iOS may free purgeable space).
    static func freeDiskBytes() -> Int64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Thrown when there isn't enough disk left to record safely.
    struct InsufficientStorageError: LocalizedError {
        var errorDescription: String? {
            "Not enough storage to record — free up some space and try again."
        }
    }

    /// Non-nil right after a recording starts with low (but sufficient) storage: a spoken-style
    /// warning with the estimated minutes remaining. The caller announces it once.
    private(set) var lowStorageWarning: String?

    // MARK: - Stream-death auto-stop

    /// Called when recording auto-stops because frames stopped arriving (glasses died: battery,
    /// thermal shutdown, out of range). Carries a spoken-style message; the file up to the stall
    /// is saved normally first.
    var onAutoStopped: ((String) -> Void)?

    /// Seconds without a frame (after at least one arrived) before recording auto-stops.
    /// `nonisolated` so `shouldAutoStop`'s default argument (evaluated outside the actor) can
    /// read it without a hop.
    nonisolated static let frameStallSeconds: TimeInterval = 15

    /// Wall-clock of the most recent appended frame (nil until the first frame arrives).
    /// Written from the background frame queue, read by the main-actor watchdog tick.
    private nonisolated(unsafe) var lastFrameAt: Date?

    /// Pure watchdog decision (testable): stop only when recording, at least one frame has ever
    /// arrived, and the stream has been silent past the stall threshold. A recording that never
    /// received a frame is left alone — the user may still be waiting for the stream to warm up.
    static func shouldAutoStop(isRecording: Bool, lastFrameAt: Date?, now: Date,
                               stallSeconds: TimeInterval = frameStallSeconds) -> Bool {
        guard isRecording, let lastFrameAt else { return false }
        return now.timeIntervalSince(lastFrameAt) >= stallSeconds
    }

    /// Start recording video + audio.
    /// - Parameters:
    ///   - publisher: Video frame publisher from CameraService
    ///   - bitrate: Explicit encoding bitrate override. `nil` (the default) derives it from the
    ///     encoded frame size and frame rate via `VideoBitratePolicy`.
    ///   - outputSize: Encoded video dimensions. Defaults to 720x1280 (glasses native).
    ///   - frameRate: Frame rate the encoder should expect. Defaults to the configured camera
    ///     rate; it feeds both the derived bitrate and the encoder's rate controller.
    func startRecording(
        from publisher: PassthroughSubject<UIImage, Never>,
        bitrate: Int? = nil,
        outputSize: CGSize? = nil,
        frameRate: Double? = nil
    ) throws {
        guard !isRecording else { return }

        let requestedWidth = Int(outputSize?.width ?? 720)
        let requestedHeight = Int(outputSize?.height ?? 1280)
        // H.264 requires even dimensions.
        let encodedWidth = max(2, (requestedWidth / 2) * 2)
        let encodedHeight = max(2, (requestedHeight / 2) * 2)
        let encodedFrameRate = frameRate ?? Double(Config.cameraFrameRate)

        // Bitrate follows the picture: derived from what we're about to encode, unless the
        // caller passed an explicit override.
        let videoBitrate = VideoBitratePolicy.bitrate(
            width: encodedWidth,
            height: encodedHeight,
            frameRate: encodedFrameRate,
            profile: .disk,
            override: bitrate
        )

        // Storage guard: refuse when a write-out would die mid-file; warn when it's just low.
        // Fed the derived bitrate — the minutes-remaining estimate is only honest at the rate
        // actually about to be written.
        lowStorageWarning = nil
        if let free = Self.freeDiskBytes() {
            switch Self.storageVerdict(freeBytes: free, videoBitrate: videoBitrate) {
            case .insufficient:
                throw InsufficientStorageError()
            case .low(let minutes):
                lowStorageWarning = "Heads up — storage is low. About \(minutes) minutes of recording space left."
            case .ok:
                break
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "OpenGlasses_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = tempDir.appendingPathComponent(fileName)

        // Clean up any previous file at this path
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        // Video input — H.264 High profile for best compatibility
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: encodedWidth,
            AVVideoHeightKey: encodedHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrate,
                AVVideoExpectedSourceFrameRateKey: Int(encodedFrameRate.rounded()),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: encodedWidth,
            kCVPixelBufferHeightKey as String: encodedHeight
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: attrs
        )

        writer.add(videoInput)

        // Audio input — AAC from the glasses/phone microphone
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.outputURL = url
        self.videoStartTime = nil
        self.audioStartTime = nil
        self.frameCount = 0
        self.pixelBufferPool = nil
        self.poolWidth = 0
        self.poolHeight = 0
        self.recordingDuration = 0
        self.recordingStartDate = Date()
        self.lastFrameAt = nil
        self.recordingTranscript = ""
        self.transcriptEntries = []
        // Start from the present: captions already buffered predate this recording.
        self.captionCursor = CaptionCursor()
        if let captions = ambientCaptionService {
            _ = self.captionCursor.take(newestFirst: captions.captionHistory)
        }
        self.isRecording = true

        // Subscribe to video frames on a background queue
        frameSubscription = publisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] image in
                self?.appendFrame(image)
            }

        // Subscribe to audio buffers from the shared audio engine
        wakeWordService?.addAudioBufferConsumer(id: Self.audioConsumerId) { [weak self] buffer in
            self?.appendAudioBuffer(buffer)
        }

        // Start ambient captions for live transcription if requested
        if autoTranscribe, let captions = ambientCaptionService {
            if !captions.isActive {
                captions.start()
            }
            // Snapshot the caption history count so we only capture new entries
            NSLog("[Recording] Auto-transcription enabled")

            // Start live meeting assistant if wired up
            if let assistant = meetingAssistant, let llmClosure = llmClosure {
                assistant.start(captionService: captions, llm: llmClosure)
            }
        }

        // Duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                // Collect new captions into transcript
                if self.autoTranscribe {
                    self.collectCaptions()
                }
                // Stream-death watchdog: if the glasses died (battery/thermal/range), stop and
                // SAVE rather than idling forever on a stalled stream.
                if Self.shouldAutoStop(isRecording: self.isRecording, lastFrameAt: self.lastFrameAt, now: Date()) {
                    await self.autoStopForStalledStream()
                }
            }
        }

        let bitrateSource = bitrate == nil ? "derived" : "override"
        NSLog("[Recording] Started (video+audio) → \(url.lastPathComponent) "
              + "(\(encodedWidth)x\(encodedHeight) @ \(Int(encodedFrameRate.rounded()))fps, "
              + "\(videoBitrate) bps \(bitrateSource))")
        hipaaService?.log(action: "RECORDING_STARTED", detail: "Video+audio recording started")
    }

    /// Stream-death auto-stop: finish and save the recording normally (everything captured up
    /// to the stall is kept), then tell the caller so it can be announced.
    private func autoStopForStalledStream() async {
        let duration = formattedDuration
        NSLog("[Recording] No frames for %.0fs — auto-stopping (glasses stream died)", Self.frameStallSeconds)
        let url = await stopRecording()
        guard url != nil else {
            onAutoStopped?("The glasses stopped sending video and the recording could not be saved.")
            return
        }
        var message = "The glasses stopped sending video, so I've ended the recording and saved "
                    + "the \(duration) captured so far."
        // A destination that didn't take is worth saying out loud — the wearer has no screen.
        if let note = lastSaveNote { message += " " + note }
        onAutoStopped?(message)
    }

    /// Stop recording and return the URL of the finished .mp4 in its **filed** location.
    ///
    /// Every path through here persists: the file is moved out of the temporary directory into
    /// Documents/Recordings, copied to the user's chosen folder when they have set one, and saved
    /// to the Glasses album in Photos unless they have turned that off. Anything that didn't land
    /// is reported on `lastSaveNote` rather than passing silently.
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        frameSubscription?.cancel()
        frameSubscription = nil
        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false

        // Stop audio consumer
        wakeWordService?.removeAudioBufferConsumer(id: Self.audioConsumerId)

        // Stop meeting assistant
        meetingAssistant?.stop()

        guard let writer, let videoInput else { return nil }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                cont.resume()
            }
        }

        let temporaryURL = outputURL
        NSLog("[Recording] Finished → %@ (%.1fs, %lld frames)",
              temporaryURL?.lastPathComponent ?? "nil", recordingDuration, frameCount)

        // Get the file out of tmp/ before anything else can go wrong with it. Everything below
        // — the transcript sidecar, file protection, the URL handed back for sharing — works
        // against the filed location, not the temporary one.
        let url = await fileFinishedRecording(temporaryURL)

        // Final caption collection
        if autoTranscribe {
            collectCaptions()
        }

        // Build final transcript with clinical header
        if !recordingTranscript.isEmpty, let videoURL = url {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .long
            dateFormatter.timeStyle = .short

            let header = """
                RECORDING TRANSCRIPT
                ====================
                Date: \(dateFormatter.string(from: recordingStartDate ?? Date()))
                Duration: \(formattedDuration)
                Source: OpenGlasses Smart Glasses Recording

                ---

                """
            let fullTranscript = header + recordingTranscript
            recordingTranscript = fullTranscript

            let transcriptURL = videoURL.deletingPathExtension().appendingPathExtension("txt")
            try? fullTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            NSLog("[Recording] Transcript saved → %@", transcriptURL.lastPathComponent)

            // Also save to Documents for Files app access and agent sharing
            saveTranscriptToDocuments(fullTranscript, date: recordingStartDate ?? Date())
        }

        // HIPAA: protect files and log the recording event
        if let videoURL = url {
            hipaaService?.protectFile(at: videoURL)
            hipaaService?.log(action: "RECORDING_STOPPED",
                              detail: "Duration: \(formattedDuration), frames: \(frameCount)")
        }

        let savedTranscribe = autoTranscribe
        autoTranscribe = false

        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.adaptor = nil
        self.outputURL = nil
        self.videoStartTime = nil
        self.audioStartTime = nil
        self.pixelBufferPool = nil

        if savedTranscribe {
            NSLog("[Recording] Transcript: %d characters", recordingTranscript.count)
        }

        return url
    }

    // MARK: - Transcription

    /// Collect new caption entries from ambient captions into the recording transcript.
    private func collectCaptions() {
        guard let captions = ambientCaptionService else { return }
        let newEntries = captionCursor.take(newestFirst: captions.captionHistory)
        guard !newEntries.isEmpty else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        for entry in newEntries {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let line = "[\(timestamp)] \(entry.text)"
            transcriptEntries.append(line)
        }
        recordingTranscript = transcriptEntries.joined(separator: "\n")
    }

    // MARK: - Persistence

    /// File a finished recording out of the temporary directory and into everywhere it belongs,
    /// returning the location it should be referred to by from now on.
    ///
    /// The destination decisions and the moves themselves live in `RecordingFiler`; this is the
    /// thin edge that resolves the user's settings, holds the security scope on a chosen folder,
    /// and performs the one step the filer deliberately leaves out — the Photos save.
    private func fileFinishedRecording(_ temporaryURL: URL?) async -> URL? {
        lastSaveNote = nil
        lastSaveSummary = nil
        guard let temporaryURL else { return nil }

        let folderURL = Config.recordingFolderURL
        if let folderURL { _ = folderURL.startAccessingSecurityScopedResource() }
        defer { folderURL?.stopAccessingSecurityScopedResource() }

        let filer = RecordingFiler(recordingsDirectory: recordingsDirectory, folderURL: folderURL)
        let wantsPhotos = Config.recordingSaveToPhotos
        var outcome = filer.file(temporaryURL,
                                 date: recordingStartDate ?? Date(),
                                 saveToPhotos: wantsPhotos)

        if wantsPhotos {
            outcome.savedToPhotos = await saveVideoToPhotos(outcome.primaryURL)
        }

        if let copyURL = outcome.folderCopyURL {
            hipaaService?.protectFile(at: copyURL)
        }
        lastSaveNote = outcome.message
        lastSaveSummary = outcome.summary
        NSLog("[Recording] Filed → %@ (photos: %@, folder copy: %@)",
              outcome.primaryURL.path,
              outcome.savedToPhotos ? "yes" : (wantsPhotos ? "failed" : "off"),
              outcome.folderCopyURL == nil ? (outcome.folderRequested ? "failed" : "none") : "yes")
        return outcome.primaryURL
    }

    // MARK: - Photos Library

    /// Save the video file to the "Glasses" album in the Photos library.
    /// Returns whether the save landed — a denied library or a failed change request is a normal
    /// outcome here, not an error, because the on-disk copy has already been written.
    @discardableResult
    private func saveVideoToPhotos(_ url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            NSLog("[Recording] Photo library access denied")
            return false
        }

        let album = fetchGlassesAlbum()

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)

                if let album {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    if let placeholder = creationRequest?.placeholderForCreatedAsset {
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                    }
                }
            }
            NSLog("[Recording] Video saved to Glasses album")
            return true
        } catch {
            NSLog("[Recording] Save to Photos failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Fetch the "Glasses" album, creating it if it doesn't exist.
    private nonisolated func fetchGlassesAlbum() -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", VideoRecordingService.albumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)

        if let existing = collections.firstObject {
            return existing
        }

        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: VideoRecordingService.albumName)
                localIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            NSLog("[Recording] Failed to create Glasses album: %@", error.localizedDescription)
            return nil
        }

        guard let identifier = localIdentifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    // MARK: - Transcript Persistence

    /// Save transcript to the user-selected folder (or Documents/Transcripts by default).
    /// Accessible via the Files app for sharing, or by the agent for summarization.
    private func saveTranscriptToDocuments(_ transcript: String, date: Date) {
        let transcriptsDir: URL
        if let customDir = Config.transcriptFolderURL {
            // User-selected folder (may need security scope for iCloud/external)
            _ = customDir.startAccessingSecurityScopedResource()
            transcriptsDir = customDir
        } else {
            let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            transcriptsDir = docsDir.appendingPathComponent("Transcripts")
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        let fileName = "transcript_\(dateFormatter.string(from: date)).txt"
        let fileURL = transcriptsDir.appendingPathComponent(fileName)

        do {
            try transcript.write(to: fileURL, atomically: true, encoding: .utf8)
            hipaaService?.protectFile(at: fileURL)
            hipaaService?.log(action: "TRANSCRIPT_SAVED", detail: fileName)
            NSLog("[Recording] Transcript saved → %@", fileURL.path)
        } catch {
            NSLog("[Recording] Failed to save transcript: %@", error.localizedDescription)
        }

        // Release security scope if we started it
        if Config.transcriptFolderURL != nil {
            transcriptsDir.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Frame Appending

    private nonisolated func appendFrame(_ image: UIImage) {
        lastFrameAt = Date()   // feeds the stream-death watchdog
        guard let cgImage = image.cgImage else { return }

        let width = cgImage.width
        let height = cgImage.height

        // Get or create a reusable pixel buffer from pool
        let buffer: CVPixelBuffer
        if let pool = pixelBufferPool, poolWidth == width, poolHeight == height {
            var poolBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &poolBuffer)
            if status == kCVReturnSuccess, let pb = poolBuffer {
                buffer = pb
            } else {
                guard let fb = createPixelBuffer(width: width, height: height) else { return }
                buffer = fb
            }
        } else {
            createPool(width: width, height: height)
            guard let fb = createPixelBuffer(width: width, height: height) else { return }
            buffer = fb
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Calculate presentation time
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let presentationTime: CMTime
        if let start = videoStartTime {
            presentationTime = CMTimeSubtract(now, start)
        } else {
            videoStartTime = now
            presentationTime = .zero
        }

        guard let adaptor, adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        adaptor.append(buffer, withPresentationTime: presentationTime)
        frameCount += 1
    }

    // MARK: - Audio Appending

    /// Append an audio buffer from the shared audio engine into the recording.
    private nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }

        let format = buffer.format
        let frameCount = buffer.frameLength

        // Convert AVAudioPCMBuffer → CMSampleBuffer for AVAssetWriter
        var sampleBuffer: CMSampleBuffer?

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

        // Calculate presentation time relative to recording start
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let start = audioStartTime {
            timing.presentationTimeStamp = CMTimeSubtract(now, start)
        } else {
            audioStartTime = now
            timing.presentationTimeStamp = .zero
        }

        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard let desc = formatDescription else { return }

        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let sb = sampleBuffer else { return }

        // Set the audio data from the PCM buffer
        let audioBufferList = buffer.audioBufferList
        CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        )

        audioInput.append(sb)
    }

    // MARK: - Pixel Buffer Pool

    private nonisolated func createPool(width: Int, height: Int) {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        pixelBufferPool = pool
        poolWidth = width
        poolHeight = height
    }

    private nonisolated func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        return status == kCVReturnSuccess ? pixelBuffer : nil
    }
}
