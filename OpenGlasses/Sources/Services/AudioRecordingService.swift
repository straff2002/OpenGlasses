import Foundation
import AVFoundation
import Combine

/// Records audio-only from the glasses/phone microphone.
///
/// Much lighter than VideoRecordingService — no camera, no pixel buffer pool,
/// no H.264 encoding. Uses the shared WakeWordService audio engine to capture
/// PCM buffers and muxes them into a .m4a via AVAssetWriter.
///
/// Integrates with AmbientCaptionService for live transcription and
/// MeetingAssistantService for real-time summarisation.
@MainActor
class AudioRecordingService: ObservableObject {
    @Published var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0

    var autoSaveToFiles = true
    var autoTranscribe = true

    weak var wakeWordService: WakeWordService?
    weak var ambientCaptionService: AmbientCaptionService?
    weak var meetingAssistant: MeetingAssistantService?
    var llmClosure: ((String) async throws -> String)?

    private var writer: AVAssetWriter?
    private nonisolated(unsafe) var audioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var audioStartTime: CMTime?
    private var outputURL: URL?
    /// A recording that began under compliance mode stays protected even if the mode is turned off
    /// before it stops.
    private var startedInComplianceMode = false
    private var durationTimer: Timer?
    private var recordingStartDate: Date?

    private(set) var recordingTranscript = ""
    private var captionCursor = CaptionCursor()

    private static let audioConsumerId = "audio_recording"

    // MARK: - Public API

    var formattedDuration: String {
        let secs = Int(recordingDuration)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func startRecording() throws {
        guard !isRecording else { return }

        // In compliance mode the writer's file is created inside a folder that already carries
        // `completeUnlessOpen`, so it is protected from its first byte — `AVAssetWriter` creates the
        // file itself, and it stays open until the recording stops.
        let complianceMode = Config.hipaaMode
        let tempDir = ComplianceFileProtection.inProgressDirectory(complianceMode: complianceMode)
        let fileName = Self.recordingFileName()
        let url = tempDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000         // Lower than video — voice-optimised
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.audioInput = audioInput
        self.outputURL = url
        self.startedInComplianceMode = complianceMode
        self.audioStartTime = nil
        self.recordingTranscript = ""
        // Start from the present: captions already buffered predate this recording.
        self.captionCursor = CaptionCursor()
        if let captions = ambientCaptionService {
            _ = self.captionCursor.take(newestFirst: captions.captionHistory)
        }
        self.recordingStartDate = Date()
        self.recordingDuration = 0
        self.isRecording = true

        // Subscribe to audio buffers from the shared engine
        wakeWordService?.addAudioBufferConsumer(id: Self.audioConsumerId) { [weak self] buffer in
            self?.appendAudioBuffer(buffer)
        }

        // Live transcription
        if autoTranscribe, let captions = ambientCaptionService {
            if !captions.isActive { captions.start() }
            PrivacyLog.speech(.meetingNotes, .started, detail: PrivacyToken("liveTranscription"))

            if let assistant = meetingAssistant, let llmClosure {
                assistant.start(captionService: captions, llm: llmClosure)
            }
        }

        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
                if self.autoTranscribe { self.collectCaptions() }
            }
        }

        // The filename is derived from the recording's own title/timestamp — an identifier
        // for a recording of the wearer's surroundings, so it is fingerprinted, never quoted.
        PrivacyLog.audio(.recording, .captureStarted,
                         device: PrivateIdentifier(url.lastPathComponent))
    }

    /// Stop recording and return the saved file URL (Documents/Recordings/).
    func stopRecording() async -> URL? {
        guard isRecording else { return nil }

        durationTimer?.invalidate()
        durationTimer = nil
        isRecording = false

        wakeWordService?.removeAudioBufferConsumer(id: Self.audioConsumerId)
        meetingAssistant?.stop()

        guard let writer else { return nil }
        audioInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        let tempURL = outputURL
        self.writer = nil
        self.audioInput = nil
        self.outputURL = nil

        guard let src = tempURL else { return nil }

        // The stop can happen with the phone locked (by voice or from the glasses), which is why
        // this is `completeUnlessOpen` and not `complete`: the latter cannot be applied then.
        let complianceMode = startedInComplianceMode || Config.hipaaMode
        startedInComplianceMode = false
        ComplianceFileProtection.protect(src, as: .recordingArtefact, complianceMode: complianceMode)

        if autoSaveToFiles {
            return Self.fileRecording(src, into: Self.recordingsDirectory,
                                      complianceMode: complianceMode)
        }
        return src
    }

    /// `Documents/Recordings`, shared with the video recorder.
    static var recordingsDirectory: URL { RecordingFiler.defaultRecordingsDirectory }

    // MARK: - Private

    /// A recording can be stopped and restarted within one second. Include a UUID so each
    /// session owns a distinct audio file instead of colliding on a timestamp-only name.
    static func recordingFileName(now: Date = Date(), id: UUID = UUID()) -> String {
        "OG_Audio_\(Int(now.timeIntervalSince1970))_\(id.uuidString).m4a"
    }

    private func collectCaptions() {
        guard let captions = ambientCaptionService else { return }
        let newEntries = captionCursor.take(newestFirst: captions.captionHistory)
        let newText = newEntries.map(\.text).joined(separator: " ")
        if !newText.isEmpty {
            recordingTranscript += (recordingTranscript.isEmpty ? "" : " ") + newText
        }
    }

    /// Move a finished recording from temporary storage into `recordingsDirectory` and, in
    /// compliance mode, protect it there. Returns where the recording ended up: the destination, or
    /// `src` when the move failed. Protection never decides whether the recording is kept.
    static func fileRecording(_ src: URL, into recordingsDirectory: URL, complianceMode: Bool,
                              fileManager: FileManager = .default) -> URL {
        try? fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        // The folder carries the class too, so anything created in it later inherits it.
        ComplianceFileProtection.protect(recordingsDirectory, as: .recordingArtefact,
                                         complianceMode: complianceMode, fileManager: fileManager)
        let dest = recordingsDirectory.appendingPathComponent(src.lastPathComponent)
        do {
            try fileManager.moveItem(at: src, to: dest)
        } catch {
            PrivacyLog.audio(.recording, .sessionConfigureFailed, error: SafeErrorSummary(error))
            return src
        }
        PrivacyLog.audio(.recording, .engineStopped,
                         device: PrivateIdentifier(dest.lastPathComponent))
        // A move within a volume normally keeps the class and the backup flag. Set both anyway,
        // rather than rely on it.
        ComplianceFileProtection.protect(dest, as: .recordingArtefact,
                                         complianceMode: complianceMode, fileManager: fileManager)
        return dest
    }

    // MARK: - Audio Buffer (nonisolated — called from audio thread)

    private nonisolated func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }

        let format = buffer.format
        let frameCount = buffer.frameLength

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount),
                            timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )

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
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let desc = formatDescription else { return }

        var sampleBuffer: CMSampleBuffer?
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

        CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )

        audioInput.append(sb)
    }
}
