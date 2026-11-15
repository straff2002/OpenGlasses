import Foundation
import AVFoundation
import os
@preconcurrency import Speech

/// Why a comparison engine failed, as a fixed token for the row and the log.
enum RecognizerComparisonError: LocalizedError, Equatable {
    case recognizerUnavailable
    case notAllowed
    case stoppedEarly(String)
    case timedOut

    var token: String {
        switch self {
        case .recognizerUnavailable: return "recognizerUnavailable"
        case .notAllowed: return "notAllowed"
        case .stoppedEarly(let reason): return "stopped-\(reason)"
        case .timedOut: return "timedOut"
        }
    }

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return String(localized: "The recogniser isn't available right now.")
        case .notAllowed: return String(localized: "This recogniser isn't allowed to run right now.")
        case .stoppedEarly: return String(localized: "The recogniser stopped before it finished.")
        case .timedOut: return String(localized: "The recogniser took too long to answer.")
        }
    }
}

/// Runs the kept utterance through every recogniser, one at a time (Plan JM P3).
///
/// Sequential on purpose: two recognisers sharing the CPU or the uplink would each look slower
/// than they are. Each engine is a `Slot` — whether it gets a row and how it transcribes — so a
/// test drives the runner with fakes; `live(onDeviceEngine:)` builds the real ones over the same
/// services dictation uses (no new network client). A cloud slot reads `CloudDictationGate` right
/// before it runs: when the gate says no, the row says "not configured" and nothing is sent, and
/// the services re-check the gate themselves.
@MainActor
final class RecognizerComparisonRunner: ObservableObject {

    enum Availability: Equatable {
        /// Run it.
        case ready
        /// Show the row, send nothing.
        case notConfigured
        /// No row at all (the engine does not exist on this phone).
        case hidden
    }

    struct Slot {
        let engine: RecognizerComparison.Engine
        let availability: () -> Availability
        let transcribe: (KeptUtterance, [String]) async throws -> String
    }

    @Published private(set) var rows: [RecognizerComparison.Row] = []
    /// The engine running right now, for the screen.
    @Published private(set) var running: RecognizerComparison.Engine?
    @Published private(set) var isRunning = false
    /// When the question the current rows ran on was captured.
    @Published private(set) var ranOn: Date?

    /// What the wearer actually said — the reference every row is scored against.
    @Published var reference = ""
    /// Whether the next run passes dictation's vocabulary hints (the device pass runs both ways).
    @Published var useHints = true
    /// Whether the current rows' run actually passed any hints.
    @Published private(set) var ranWithHints = false
    /// Rows across questions, in memory only, for as long as the app lives.
    @Published private(set) var session = RecognizerComparison.Session()
    /// Whether the current rows are already in the session (one add per run).
    @Published private(set) var addedToSession = false

    let slots: [Slot]
    var now: () -> Date = { Date() }

    init(slots: [Slot]) {
        self.slots = slots
    }

    /// Run every slot, in order, on `utterance`, with `vocabulary` passed as dictation passes it.
    @discardableResult
    func run(_ utterance: KeptUtterance, vocabulary: [String]) async -> [RecognizerComparison.Row] {
        guard !isRunning else { return rows }
        isRunning = true
        rows = []
        addedToSession = false
        ranOn = utterance.capturedAt
        ranWithHints = !vocabulary.isEmpty
        defer {
            isRunning = false
            running = nil
        }
        for slot in slots {
            switch slot.availability() {
            case .hidden:
                continue
            case .notConfigured:
                rows.append(.init(engine: slot.engine, transcript: "", elapsed: 0, outcome: .notConfigured))
            case .ready:
                running = slot.engine
                let started = now()
                do {
                    let text = try await slot.transcribe(utterance, vocabulary)
                    rows.append(.init(engine: slot.engine, transcript: text,
                                      elapsed: now().timeIntervalSince(started), outcome: .transcribed))
                } catch {
                    rows.append(.init(engine: slot.engine, transcript: "",
                                      elapsed: now().timeIntervalSince(started),
                                      outcome: .failed(Self.token(for: error)),
                                      message: error.localizedDescription))
                }
            }
            if let row = rows.last, row.engine == slot.engine {
                // The engine and how it ended, as tokens; never the words.
                PrivacyLog.speech(.dictation, .comparisonRan, seconds: row.elapsed,
                                  detail: PrivacyToken("\(slot.engine.rawValue).\(row.outcome.token)"))
            }
        }
        return rows
    }

    /// Add the current rows, scored against `reference`, to the session. Once per run.
    func addToSession() {
        guard !rows.isEmpty, !addedToSession, !isRunning else { return }
        session.add(rows: rows, reference: reference, hints: ranWithHints)
        addedToSession = true
    }

    func clearSession() {
        session.clear()
        addedToSession = false
    }

    /// A fixed token for a failure — never the error's own text.
    static func token(for error: Error) -> String {
        if let comparison = error as? RecognizerComparisonError { return comparison.token }
        if let openAI = error as? OpenAIDictationError { return openAI.token }
        if error is MedicalEgressRefusal { return "medicalLocalOnly" }
        if error is ASRError { return "onDeviceFailed" }
        if error is CancellationError { return "cancelled" }
        return "failed"
    }

    // MARK: - The live engines

    /// The real recognisers, in the order the table lists them. `onDeviceEngine` is dictation's
    /// own, so the SenseVoice model is not loaded twice.
    static func live(onDeviceEngine: OnDeviceASREngine,
                     gate: @escaping () -> CloudDictationGate = { .live }) -> RecognizerComparisonRunner {
        let slots: [Slot] = [
            Slot(engine: .appleSpeech,
                 availability: { .ready },
                 transcribe: { utterance, vocabulary in
                     try await appleSpeech(utterance, vocabulary: vocabulary, onDevice: false)
                 }),
            Slot(engine: .appleSpeechOnDevice,
                 availability: {
                     SFSpeechRecognizer(locale: SpeechLocaleResolver.current)?.supportsOnDeviceRecognition == true
                         ? .ready : .hidden
                 },
                 transcribe: { utterance, vocabulary in
                     try await appleSpeech(utterance, vocabulary: vocabulary, onDevice: true)
                 }),
            Slot(engine: .onDevice,
                 availability: { onDeviceEngine.isReady ? .ready : .hidden },
                 transcribe: { utterance, _ in
                     // SenseVoice takes no hints, in dictation and here.
                     try await onDeviceEngine.transcribe(samples: utterance.samples, sampleRate: utterance.sampleRate)
                 }),
            Slot(engine: .deepgram,
                 availability: { gate().isConfigured(provider: .deepgram) ? .ready : .notConfigured },
                 transcribe: { utterance, vocabulary in
                     try await deepgram(utterance, vocabulary: vocabulary, gate: gate)
                 }),
            Slot(engine: .openAI,
                 availability: { gate().isConfigured(provider: .openAI) ? .ready : .notConfigured },
                 transcribe: { utterance, vocabulary in
                     let service = OpenAIDictationService()
                     service.isAllowed = { gate().isConfigured(provider: .openAI) }
                     return try await service.transcribe(samples: utterance.samples,
                                                         sampleRate: utterance.sampleRate,
                                                         vocabulary: vocabulary)
                 }),
        ]
        return RecognizerComparisonRunner(slots: slots)
    }

    /// The kept samples as a run of 100 ms mono float buffers at the capture rate — the shape the
    /// dictation tap hands Apple Speech and the Deepgram converter.
    static func buffers(for utterance: KeptUtterance) -> [AVAudioPCMBuffer] {
        guard utterance.sampleRate > 0, !utterance.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: utterance.sampleRate, channels: 1)
        else { return [] }
        let chunk = max(Int(utterance.sampleRate / 10), 1)
        var result: [AVAudioPCMBuffer] = []
        var start = 0
        utterance.samples.withUnsafeBufferPointer { source in
            while start < source.count {
                let count = min(chunk, source.count - start)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0],
                      let base = source.baseAddress else { break }
                channel.update(from: base + start, count: count)
                buffer.frameLength = AVAudioFrameCount(count)
                result.append(buffer)
                start += count
            }
        }
        return result
    }

    /// Apple Speech on the kept audio: buffers appended to a request, then `endAudio()`, and the
    /// final result. Server-capable as dictation uses it, or forced on-device.
    static func appleSpeech(_ utterance: KeptUtterance, vocabulary: [String], onDevice: Bool,
                            timeout: TimeInterval = 60) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current),
              recognizer.isAvailable else {
            throw RecognizerComparisonError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if onDevice { request.requiresOnDeviceRecognition = true }
        if !vocabulary.isEmpty { request.contextualStrings = vocabulary }
        let buffers = buffers(for: utterance)

        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if once.claim() { continuation.resume(throwing: error) }
                } else if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                }
            }
            for buffer in buffers { request.append(buffer) }
            request.endAudio()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard once.claim() else { return }
                task.cancel()
                continuation.resume(throwing: RecognizerComparisonError.timedOut)
            }
        }
    }

    /// Deepgram on the kept audio, through dictation's own service: `start`, every buffer through
    /// the same `PCMConverter.linear16Mono` path, then `finish` (with room for a burst of audio to
    /// be worked through, where live dictation allows 1.5 s).
    static func deepgram(_ utterance: KeptUtterance, vocabulary: [String],
                         gate: @escaping () -> CloudDictationGate) async throws -> String {
        let service = DeepgramDictationService()
        service.isAllowed = { gate().isConfigured(provider: .deepgram) }
        var stoppedReason: String?
        service.onStopped = { reason in stoppedReason = reason }
        guard service.start(vocabulary: vocabulary) else { throw RecognizerComparisonError.notAllowed }
        let rate = Int(utterance.sampleRate.rounded())
        for buffer in buffers(for: utterance) {
            service.sendAudio(PCMConverter.linear16Mono(from: buffer), sampleRate: rate)
            if stoppedReason != nil { break }
        }
        let text = await service.finish(closeTimeout: 10)
        if let reason = stoppedReason { throw RecognizerComparisonError.stoppedEarly(reason) }
        return text
    }
}

/// Resume a continuation once, whichever of the recogniser and the timeout answers first.
private final class ResumeOnce: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        lock.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}
