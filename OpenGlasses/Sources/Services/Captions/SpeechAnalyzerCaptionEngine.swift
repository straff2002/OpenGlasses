import AVFoundation
import Foundation
import Speech

/// Which recogniser the plain caption path runs (pure, headless-tested).
///
/// iOS 26's `SpeechAnalyzer` with a `SpeechTranscriber` is made for long-form audio: on-device,
/// no per-request time limit and no restart after each result, so a meeting is heard end to end.
/// `SFSpeechRecognizer` restarts on every final result and after every error, and loses the
/// audio of each restart. The analyzer is used when the developer switch is on
/// (`Config.captionSpeechAnalyzerEnabled`), the caption locale is supported and its model is on
/// the phone; a supported locale whose model is not yet installed runs `SFSpeechRecognizer` this
/// session and asks Apple for the model in the background, so the next session has it. Any start
/// or stream error falls back to `SFSpeechRecognizer` for the rest of the captions session.
/// Translation and diarization keep their precedence; this is only the plain path.
enum CaptionEnginePolicy {

    enum Availability: Equatable, Sendable {
        /// No `SpeechTranscriber` for this locale on this phone, or none at all.
        case unsupported
        /// Supported, but its model is not installed (or is still downloading).
        case supportedNotInstalled
        case installed
    }

    enum Decision: Equatable, Sendable {
        case speechAnalyzer
        /// `SFSpeechRecognizer`; `installAssets` asks for the analyzer's model in the background.
        case sfSpeech(installAssets: Bool)
    }

    /// Whether the plain path tries the analyzer at all before its (async) availability check.
    static func shouldTry(enabled: Bool, fellBackThisSession: Bool) -> Bool {
        enabled && !fellBackThisSession
    }

    static func decide(enabled: Bool, fellBackThisSession: Bool, availability: Availability) -> Decision {
        guard shouldTry(enabled: enabled, fellBackThisSession: fellBackThisSession) else {
            return .sfSpeech(installAssets: false)
        }
        switch availability {
        case .installed: return .speechAnalyzer
        case .supportedNotInstalled: return .sfSpeech(installAssets: true)
        case .unsupported: return .sfSpeech(installAssets: false)
        }
    }

    /// The asset inventory's status, read as availability. A model still downloading is not
    /// installed yet: this session runs `SFSpeechRecognizer`.
    static func availability(supported: Bool, status: AssetInventory.Status?) -> Availability {
        guard supported, let status else { return .unsupported }
        switch status {
        case .installed: return .installed
        case .supported, .downloading: return .supportedNotInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// What a transcriber result means for the caption: a volatile line replaces the live text, a
    /// final one is committed. An empty final commits nothing; an empty volatile clears the line.
    static func event(text: String, isFinal: Bool) -> SpeechAnalyzerCaptionEngine.Event? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { return trimmed.isEmpty ? nil : .final(trimmed) }
        return .volatile(trimmed)
    }

    /// Output frames a resampling conversion needs for `frames` input frames, with headroom: a
    /// resampler's output for one block is not exactly the ratio.
    static func outputCapacity(frames: AVAudioFrameCount, from inputRate: Double, to outputRate: Double) -> AVAudioFrameCount {
        guard inputRate > 0, outputRate > 0 else { return frames + 64 }
        return AVAudioFrameCount((Double(frames) * outputRate / inputRate).rounded(.up)) + 64
    }

    /// How much audio may wait for the analyzer to be ready (its format is known only once the
    /// model answers): a couple of seconds, so the first words are not lost, and no more.
    static let queuedSecondsLimit: Double = 3
}

/// Mic buffers on their way to the analyzer: converted to its format with `AVAudioConverter`,
/// held for a moment until that format is known, then fed to the analyzer's input stream. Called
/// on the audio thread by the caption consumer (behind the assistant-voice gate, like every
/// caption path), so it locks rather than hopping to the main actor per buffer.
final class CaptionAnalyzerAudioFeed: @unchecked Sendable {

    private let lock = NSLock()
    private var target: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var convertingFrom: AVAudioFormat?
    private var queued: [AVAudioPCMBuffer] = []
    private var queuedSeconds: Double = 0
    private var finished = false
    private(set) var conversionFailures = 0

    /// One mic buffer. Before the analyzer is ready it waits (up to `queuedSecondsLimit`, the
    /// oldest going first); after `finish()` it is dropped.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        guard let target, let continuation else {
            queued.append(buffer)
            queuedSeconds += Self.seconds(buffer)
            while queuedSeconds > CaptionEnginePolicy.queuedSecondsLimit, queued.count > 1 {
                queuedSeconds -= Self.seconds(queued.removeFirst())
            }
            return
        }
        feed(buffer, to: target, continuation)
    }

    /// The analyzer's format is known and its input stream open: what waited goes first.
    func ready(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            continuation.finish()
            return
        }
        target = format
        self.continuation = continuation
        let waiting = queued
        queued = []
        queuedSeconds = 0
        for buffer in waiting { feed(buffer, to: format, continuation) }
    }

    /// No more audio: the input stream ends and later buffers are dropped.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        queued = []
        continuation?.finish()
        continuation = nil
        converter = nil
    }

    private func feed(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat,
                      _ continuation: AsyncStream<AnalyzerInput>.Continuation) {
        guard let converted = convert(buffer, to: format) else {
            conversionFailures += 1
            return
        }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        if buffer.format == format { return buffer }
        if converter == nil || convertingFrom != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            convertingFrom = buffer.format
        }
        guard let converter else { return nil }
        let capacity = CaptionEnginePolicy.outputCapacity(frames: buffer.frameLength,
                                                          from: buffer.format.sampleRate, to: format.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // One block per call; `.noDataNow` keeps a resampling converter from spinning.
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        switch status {
        case .haveData, .inputRanDry: return output.frameLength > 0 ? output : nil
        case .endOfStream, .error: return nil
        @unknown default: return nil
        }
    }

    private static func seconds(_ buffer: AVAudioPCMBuffer) -> Double {
        buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
    }
}

/// Long-form on-device captions through `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26). One
/// engine per recognition session: `start` checks the locale and its model, then runs until
/// `stop`, with no restart between results. Volatile results are the live line; finals are
/// committed captions. The live engine needs a device; the policy and the result mapping it
/// relies on are tested (`CaptionEnginePolicy`).
@MainActor
final class SpeechAnalyzerCaptionEngine {

    enum Event: Equatable, Sendable {
        case volatile(String)
        case final(String)
    }

    enum EngineError: Error {
        case noAudioFormat
        case localeUnsupported
    }

    /// Results, on the main actor, while the engine runs.
    var onEvent: ((Event) -> Void)?
    /// The locale cannot run on the analyzer this session (unsupported, or its model is not
    /// installed); the caller starts `SFSpeechRecognizer` instead.
    var onUnavailable: ((CaptionEnginePolicy.Availability) -> Void)?
    /// The analyzer failed to start or its results ended in an error; the caller falls back.
    var onFailure: ((Error) -> Void)?

    /// The audio path in: the caption consumer appends every buffer here.
    let feed = CaptionAnalyzerAudioFeed()

    /// The live line not yet finalised, which `stop` hands back so the caller can commit it.
    private(set) var volatileText = ""

    private var analyzer: SpeechAnalyzer?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var stopped = false

    func start(locale: Locale, contextualStrings: [String]) {
        setupTask = Task { [weak self] in
            await self?.run(locale: locale, contextualStrings: contextualStrings)
        }
    }

    /// End the session at once. Results still in flight are not waited for: the live line is the
    /// caller's to commit (`volatileText`), so a stop is as immediate as the recogniser's.
    func stop() {
        guard !stopped else { return }
        stopped = true
        feed.finish()
        setupTask?.cancel()
        resultsTask?.cancel()
        setupTask = nil
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        onEvent = nil
        onUnavailable = nil
        onFailure = nil
    }

    // MARK: - Running

    private func run(locale: Locale, contextualStrings: [String]) async {
        let (availability, supported) = await Self.availability(for: locale)
        guard !stopped else { return }
        guard availability == .installed, let supported else {
            onUnavailable?(availability)
            return
        }
        do {
            let transcriber = Self.makeTranscriber(locale: supported)
            let modules: [any SpeechModule] = [transcriber]
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw EngineError.noAudioFormat
            }
            let analyzer = SpeechAnalyzer(modules: modules)
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            guard !stopped else {
                await analyzer.cancelAndFinishNow()
                return
            }
            self.analyzer = analyzer
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, !self.stopped else { return }
                        self.handle(text: String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    self?.fail(error)
                }
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            feed.ready(format: format, continuation: continuation)
            try await analyzer.start(inputSequence: stream)
            PrivacyLog.speech(.ambientCaptions, .engineSelected, language: PrivacyToken(supported.identifier),
                              detail: PrivacyToken("speechAnalyzer"))
        } catch {
            fail(error)
        }
    }

    private func handle(text: String, isFinal: Bool) {
        guard let event = CaptionEnginePolicy.event(text: text, isFinal: isFinal) else {
            if isFinal { volatileText = "" }
            return
        }
        switch event {
        case .volatile(let line): volatileText = line
        case .final: volatileText = ""
        }
        onEvent?(event)
    }

    private func fail(_ error: Error) {
        guard !stopped, !(error is CancellationError) else { return }
        let handler = onFailure
        stop()
        handler?(error)
    }

    // MARK: - The model

    /// The one configuration both the session and the background install use: the installed
    /// model is matched by configuration, not by object.
    nonisolated static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    /// Whether `locale` can run on the analyzer now, and the transcriber's own equivalent of it.
    nonisolated static func availability(for locale: Locale) async -> (CaptionEnginePolicy.Availability, Locale?) {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return (.unsupported, nil)
        }
        let status = await AssetInventory.status(forModules: [makeTranscriber(locale: supported)])
        return (CaptionEnginePolicy.availability(supported: true, status: status), supported)
    }

    /// Ask Apple for the analyzer's model for `locale`, so the next captions session can use it.
    /// One request per process and locale. On-device model data only: no audio or text leaves.
    static func installAssetsInBackground(for locale: Locale) {
        let key = locale.identifier
        guard !installsRequested.contains(key) else { return }
        installsRequested.insert(key)
        Task.detached(priority: .utility) {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
            PrivacyLog.speech(.ambientCaptions, .assetsRequested, language: PrivacyToken(supported.identifier))
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [makeTranscriber(locale: supported)]) {
                    try await request.downloadAndInstall()
                }
                PrivacyLog.speech(.ambientCaptions, .assetsInstalled, language: PrivacyToken(supported.identifier))
            } catch {
                PrivacyLog.speech(.ambientCaptions, .assetsFailed, language: PrivacyToken(supported.identifier),
                                  error: SafeErrorSummary(error))
            }
        }
    }

    private static var installsRequested: Set<String> = []
}
