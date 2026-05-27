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
/// - Auto-save to Photos library ("Glasses" album) when enabled
/// - Efficient pixel buffer pooling to minimize allocations during long sessions
/// - Background audio session keeps the app alive in the pocket
@MainActor
class VideoRecordingService: ObservableObject {
    @Published var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0

    /// When true, the finished recording is automatically saved to the Photos library.
    var autoSaveToPhotos = false

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

    var formattedDuration: String {
        let hours = Int(recordingDuration) / 3600
        let mins = (Int(recordingDuration) % 3600) / 60
        let secs = Int(recordingDuration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }

    /// Start recording video + audio.
    /// - Parameters:
    ///   - publisher: Video frame publisher from CameraService
    ///   - bitrate: Video encoding bitrate (default 1.5 Mbps)
    ///   - outputSize: Encoded video dimensions. Defaults to 720x1280 (glasses native).
    func startRecording(
        from publisher: PassthroughSubject<UIImage, Never>,
        bitrate: Int = 1_500_000,
        outputSize: CGSize? = nil
    ) throws {
        guard !isRecording else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "OpenGlasses_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = tempDir.appendingPathComponent(fileName)

        // Clean up any previous file at this path
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let requestedWidth = Int(outputSize?.width ?? 720)
        let requestedHeight = Int(outputSize?.height ?? 1280)
        // H.264 requires even dimensions.
        let encodedWidth = max(2, (requestedWidth / 2) * 2)
        let encodedHeight = max(2, (requestedHeight / 2) * 2)

        // Video input — H.264 High profile for best compatibility
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: encodedWidth,
            AVVideoHeightKey: encodedHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
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
        self.recordingTranscript = ""
        self.transcriptEntries = []
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
            }
        }

        NSLog("[Recording] Started (video+audio) → %@ (%dx%d @ %d bps)",
              url.lastPathComponent, encodedWidth, encodedHeight, bitrate)
        hipaaService?.log(action: "RECORDING_STARTED", detail: "Video+audio recording started")
    }

    /// Stop recording and return the URL of the finished .mp4.
    /// If `autoSaveToPhotos` is true, the video is saved to the Glasses album.
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

        let url = outputURL
        NSLog("[Recording] Finished → %@ (%.1fs, %lld frames)",
              url?.lastPathComponent ?? "nil", recordingDuration, frameCount)

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

        // Auto-save to Photos if enabled
        if autoSaveToPhotos, let videoURL = url {
            await saveVideoToPhotos(videoURL)
            autoSaveToPhotos = false
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
        let history = captions.captionHistory
        let newCount = history.count - transcriptEntries.count
        guard newCount > 0 else { return }

        // captionHistory is newest-first, so take the new entries from the front
        let newEntries = history.prefix(newCount)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        for entry in newEntries.reversed() {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let line = "[\(timestamp)] \(entry.text)"
            transcriptEntries.append(line)
        }
        recordingTranscript = transcriptEntries.joined(separator: "\n")
    }

    // MARK: - Photos Library

    /// Save the video file to the "Glasses" album in the Photos library.
    private func saveVideoToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            NSLog("[Recording] Photo library access denied")
            return
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
        } catch {
            NSLog("[Recording] Save to Photos failed: %@", error.localizedDescription)
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
