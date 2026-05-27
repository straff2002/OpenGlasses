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
    private var durationTimer: Timer?
    private var recordingStartDate: Date?

    private(set) var recordingTranscript = ""
    private var lastCaptionCount = 0

    private static let audioConsumerId = "audio_recording"

    // MARK: - Public API

    var formattedDuration: String {
        let secs = Int(recordingDuration)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    func startRecording() throws {
        guard !isRecording else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "OG_Audio_\(Int(Date().timeIntervalSince1970)).m4a"
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
        self.audioStartTime = nil
        self.recordingTranscript = ""
        self.lastCaptionCount = 0
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
            NSLog("[AudioRecording] Live transcription enabled")

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

        NSLog("[AudioRecording] Started → %@", url.lastPathComponent)
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

        if autoSaveToFiles {
            return saveToDocuments(src)
        }
        return src
    }

    // MARK: - Private

    private func collectCaptions() {
        guard let captions = ambientCaptionService else { return }
        let history = captions.captionHistory
        guard history.count > lastCaptionCount else { return }
        let newEntries = history[lastCaptionCount...]
        let newText = newEntries.map(\.text).joined(separator: " ")
        if !newText.isEmpty {
            recordingTranscript += (recordingTranscript.isEmpty ? "" : " ") + newText
        }
        lastCaptionCount = history.count
    }

    private func saveToDocuments(_ src: URL) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recDir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
        let dest = recDir.appendingPathComponent(src.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            NSLog("[AudioRecording] Saved → %@", dest.path)
            return dest
        } catch {
            NSLog("[AudioRecording] Save failed: %@", error.localizedDescription)
            return src
        }
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
