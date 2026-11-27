import AVFoundation
import Foundation
import Speech

/// The recorder's ears on the phone (Plan IM P1): the microphone through the capture router, an
/// `.m4a` beside the transcript, and **on-device recognition only**.
///
/// The router is the one mic source captures talk to (`CaptureAudioRouter`): it swaps between the
/// wake word's tap and a standalone engine as listening is toggled, holds one format across a
/// handover, and silences the assistant's voice out of the phone speaker. This capture registers
/// on it like any recording does.
///
/// Recognition is `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, set unconditionally:
/// where the phone cannot transcribe its language on the device, `prepare()` refuses rather than
/// fall back to Apple's servers, because P1 sends nothing anywhere. A stretch is what was said
/// between pauses: when the words stop changing for `pause` seconds the stretch is handed over and
/// a fresh request takes the audio that follows, so no request runs long and a marker is read as
/// soon as it has been said.
@MainActor
final class LiveExperienceCapture: ExperienceCapture {

    static let consumerId = "experience_recording"
    /// Quiet long enough to end a stretch.
    static let pause: TimeInterval = 1.6

    private weak var audio: CaptureAudioRouter?
    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?
    private let sink = Sink()
    private var writer: AVAssetWriter?
    private var outputURL: URL?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var pending = ""
    private var lastChange = Date()
    private var requestStartedAt = Date()
    private var quickFailures = 0
    private var pauseWatch: Task<Void, Never>?
    private var onStretch: (@MainActor (String) -> Void)?
    private var onFailure: (@MainActor (String) -> Void)?
    private var stopped = false

    init(audio: CaptureAudioRouter?, locale: Locale = SpeechLocaleResolver.current) {
        self.audio = audio
        self.locale = locale
    }

    // MARK: - Preparing

    /// Why recording cannot start, from what the phone reports. Pure, so each refusal is a test.
    nonisolated static func refusal(speechAuthorized: Bool, microphoneAllowed: Bool,
                                    recognizerExists: Bool, onDeviceSupported: Bool) -> String? {
        guard microphoneAllowed else {
            return String(localized: "Recording experience needs the microphone. Allow it for Avenkin in Settings.")
        }
        guard speechAuthorized else {
            return String(localized: "Recording experience needs speech recognition. Allow it for Avenkin in Settings.")
        }
        guard recognizerExists, onDeviceSupported else {
            return String(localized: "This phone can't transcribe your language without the internet, and a recording is only ever transcribed on the phone, so nothing can be recorded.")
        }
        return nil
    }

    func prepare() async -> String? {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        var microphone = AVAudioApplication.shared.recordPermission == .granted
        if AVAudioApplication.shared.recordPermission == .undetermined {
            microphone = await AVAudioApplication.requestRecordPermission()
        }
        let recognizer = SFSpeechRecognizer(locale: locale)
        self.recognizer = recognizer
        return Self.refusal(speechAuthorized: status == .authorized, microphoneAllowed: microphone,
                            recognizerExists: recognizer != nil,
                            onDeviceSupported: recognizer?.supportsOnDeviceRecognition ?? false)
    }

    // MARK: - Recording

    func start(writingTo url: URL,
               onStretch: @escaping @MainActor (String) -> Void,
               onFailure: @escaping @MainActor (String) -> Void) throws {
        if recognizer == nil { recognizer = SFSpeechRecognizer(locale: locale) }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw CaptureError.onDeviceRecognitionUnavailable
        }
        guard let audio else { throw CaptureError.noMicrophone }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        RecordingProvenanceMetadata.apply(to: writer, assistantVoiceMayBeIncluded: audio.assistantVoiceMayBeIncluded)
        guard writer.startWriting() else { throw CaptureError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        Self.protect(url)

        self.writer = writer
        outputURL = url
        self.onStretch = onStretch
        self.onFailure = onFailure
        stopped = false
        sink.attach(input)
        beginRecognition(with: recognizer)
        let sink = self.sink
        audio.addAudioBufferConsumer(id: Self.consumerId) { buffer in sink.append(buffer) }
        watchForPauses()
    }

    func stop() async -> ExperienceCaptureEnding {
        guard !stopped else { return ExperienceCaptureEnding(audioWritten: false, lastStretch: nil) }
        stopped = true
        pauseWatch?.cancel()
        pauseWatch = nil
        audio?.removeAudioBufferConsumer(id: Self.consumerId)
        let last = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        generation += 1
        sink.replace(request: nil)?.endAudio()
        task?.cancel()
        task = nil
        let input = sink.detach()
        input?.markAsFinished()
        if let writer {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.finishWriting { done.resume() }
            }
        }
        writer = nil
        onStretch = nil
        onFailure = nil
        let written = outputURL.map { AudioRecordingService.discardingEmptyCapture($0) != nil } ?? false
        outputURL = nil
        return ExperienceCaptureEnding(audioWritten: written, lastStretch: last.isEmpty ? nil : last)
    }

    // MARK: - Stretches

    private func beginRecognition(with recognizer: SFSpeechRecognizer) {
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never Apple's servers: P1 sends nothing off the phone.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        sink.replace(request: request)?.endAudio()
        task?.cancel()
        pending = ""
        requestStartedAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                self?.received(text: text, isFinal: isFinal, failed: failed, generation: current)
            }
        }
    }

    private func received(text: String?, isFinal: Bool, failed: Bool, generation current: Int) {
        guard current == generation, !stopped else { return }
        if let text, !text.isEmpty, text != pending {
            pending = text
            lastChange = Date()
            quickFailures = 0
        }
        guard isFinal || failed else { return }
        // A request that fails the moment it starts, again and again, is a recogniser that has
        // gone; one that ends after a quiet spell is ordinary and simply starts again.
        if failed, pending.isEmpty, Date().timeIntervalSince(requestStartedAt) < 1 {
            quickFailures += 1
        }
        handOver()
        if quickFailures >= 5 {
            onFailure?(String(localized: "Transcription stopped on this phone."))
            return
        }
        if let recognizer { beginRecognition(with: recognizer) }
    }

    private func handOver() {
        let stretch = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        if !stretch.isEmpty { onStretch?(stretch) }
    }

    private func watchForPauses() {
        pauseWatch?.cancel()
        pauseWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !self.stopped else { return }
                if !self.pending.isEmpty, Date().timeIntervalSince(self.lastChange) >= Self.pause {
                    self.handOver()
                    if let recognizer = self.recognizer { self.beginRecognition(with: recognizer) }
                }
            }
        }
    }

    private static func protect(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        for target in [folder, url] where FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.setAttributes(
                [.protectionKey: ExperienceRecordingStore.fileProtection], ofItemAtPath: target.path)
        }
    }

    enum CaptureError: Error {
        case onDeviceRecognitionUnavailable
        case noMicrophone
        case writerFailed
    }

    // MARK: - The audio thread

    /// What the audio thread writes to: the file's input and the recogniser's current request,
    /// swapped under a lock as stretches turn over.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var input: AVAssetWriterInput?
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var startTime: CMTime?

        func attach(_ input: AVAssetWriterInput) {
            lock.lock(); defer { lock.unlock() }
            self.input = input
            startTime = nil
        }

        func detach() -> AVAssetWriterInput? {
            lock.lock(); defer { lock.unlock() }
            let old = input
            input = nil
            return old
        }

        /// Put `request` in place and return the one it replaced.
        @discardableResult
        func replace(request: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
            lock.lock(); defer { lock.unlock() }
            let old = self.request
            self.request = request
            return old
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
            guard let input, input.isReadyForMoreMediaData else { return }
            let format = buffer.format
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let presentation: CMTime
            if let startTime {
                presentation = CMTimeSubtract(now, startTime)
            } else {
                startTime = now
                presentation = .zero
            }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: CMTimeValue(buffer.frameLength), timescale: CMTimeScale(format.sampleRate)),
                presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
            var description: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
                                           layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &description)
            guard let description else { return }
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                 makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                                 sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                 sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                 sampleBufferOut: &sample)
            guard let sample else { return }
            CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                           blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                           flags: 0, bufferList: buffer.audioBufferList)
            input.append(sample)
        }
    }
}
