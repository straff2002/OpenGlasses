import Foundation
import Combine
import Speech
import AVFoundation

/// How the teleprompter advances. Speed is a separate, live setting (`PacingSpeed`).
enum PacingMode: String, CaseIterable, Codable, Equatable {
    /// Auto-advances by listening to what you actually say (the headline mode).
    case audioPaced
    /// No auto-advance — you drive with "next"/"back" (voice or band).
    case voice
    /// Fixed WPM auto-scroll on a timer.
    case autoScroll

    var displayName: String {
        switch self {
        case .audioPaced: return "Audio-paced"
        case .voice: return "Voice (manual)"
        case .autoScroll: return "Auto-scroll"
        }
    }
}

/// Orchestrates the audio-paced HUD teleprompter (Phase 2): it owns the in-lens display
/// while active (reusing `GlassesDisplayService`'s interactive gate, so ambient producers
/// are suppressed like a task card), streams recognized speech into the pure `ScriptAligner`
/// to keep your place, paginates the cursor into an `HUDScreen`, and mirrors that screen to
/// the phone via `currentScreen` (so it works device-less).
///
/// The deterministic seams — `ingestForPacing`, `handleVoiceCommand`, `advance`/`back`,
/// `nudgeSpeed`, `autoScrollStep` — are pure of audio/hardware and fully unit-tested. Live
/// `SFSpeechRecognizer` streaming (device-pending) is a thin shell that feeds those seams;
/// it only starts when a `WakeWordService` audio source is wired, so tests stay headless.
@MainActor
final class TeleprompterService: ObservableObject {
    /// True while a session is running (whether playing or paused).
    @Published private(set) var isActive = false
    /// True when auto-pacing is held; "resume" still works while paused.
    @Published private(set) var isPaused = false
    /// The screen currently on the lens — published so `HUDPreviewView` mirrors it on the phone.
    @Published private(set) var currentScreen: HUDScreen?
    /// 0…1 through the whole script.
    @Published private(set) var progress: Double = 0
    @Published private(set) var mode: PacingMode = .audioPaced

    let store: TeleprompterScriptStore

    /// Audio source for live recognition (the shared engine). When nil (tests), no live
    /// recognition is started — the pacing seams are driven directly instead.
    weak var wakeWordService: WakeWordService?
    /// In-lens display. When nil (tests / no display), `currentScreen` still updates so the
    /// on-phone mirror and headless tests can observe the exact frames.
    weak var glassesDisplay: GlassesDisplayService?

    /// Glasses camera for vision capture (Phase 4). When nil (tests / no glasses), `scanPage`
    /// reports unavailable; `ingestScannedImage` is driven directly instead.
    weak var camera: (any FilteredStillProviding)?
    /// JPEG → recognized text (on-device OCR). Injectable so the scan flow is unit-testable
    /// without Vision or a camera; defaults to `OCRService`.
    var ocr: ((Data) async -> String)? = { await OCRService().recognizeText(in: $0).text }

    /// Accumulated OCR'd text from one or more captured pages, awaiting "start"/"save".
    @Published private(set) var scanBuffer = ""
    @Published private(set) var scanPages = 0
    var hasScannedPages: Bool { scanPages > 0 }

    private(set) var script: TeleprompterScript?
    private var normalizedTokens: [String] = []
    private(set) var cursor = 0
    private(set) var pacing = PacingSpeed()

    /// HUD geometry for the script window — one line is reserved for the status row.
    private var geometry = TeleprompterPaginator.Geometry(maxLines: 3, maxChars: 32)

    // Live recognition (device-pending shell).
    private let recognizer = SFSpeechRecognizer(locale: SpeechLocaleResolver.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    static let recognitionConsumerID = "teleprompter"

    // Auto-scroll timer.
    private var autoScrollTimer: Timer?

    /// Cap on the recognized tail handed to the aligner — bounds work and keeps matching local.
    static let maxHeardTail = 16

    init(store: TeleprompterScriptStore) {
        self.store = store
        pacing = PacingSpeed(wpm: Config.teleprompterWPM,
                             leadLines: Config.teleprompterLead,
                             responsiveness: 0.5)
        mode = Config.teleprompterMode
    }

    // MARK: - Lifecycle

    /// Start prompting `script`. Defaults to the persisted pacing mode.
    func start(_ script: TeleprompterScript, mode: PacingMode? = nil) {
        stopRecognition()
        stopAutoScroll()

        self.script = script
        normalizedTokens = script.tokens.map(\.normalized)
        cursor = 0
        self.mode = mode ?? Config.teleprompterMode
        isActive = true
        isPaused = false
        render()

        switch self.mode {
        case .audioPaced: startRecognition()
        case .autoScroll: startAutoScroll()
        case .voice: break
        }
    }

    /// Start a saved script by id. Returns false if no such script exists.
    @discardableResult
    func start(savedID id: UUID, mode: PacingMode? = nil) -> Bool {
        guard let saved = store.script(withID: id) else { return false }
        start(TeleprompterScript.parse(title: saved.title, text: saved.text), mode: mode)
        return true
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        stopRecognition()
        stopAutoScroll()
        script = nil
        normalizedTokens = []
        cursor = 0
        currentScreen = nil
        progress = 0
        glassesDisplay?.endInteractive()
    }

    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        stopAutoScroll()           // recognition keeps running so "resume" can be heard
        render()
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        if mode == .autoScroll { startAutoScroll() }
        render()
    }

    func restart() {
        guard isActive else { return }
        cursor = 0
        render()
    }

    /// Advance to the start of the next source line.
    func advance() {
        guard isActive, let script else { return }
        let line = lineOf(cursor)
        if let idx = script.tokens.firstIndex(where: { $0.line > line }) {
            cursor = idx
        } else {
            cursor = script.wordCount
        }
        render()
        checkCompletion()
    }

    /// Go back to the start of the previous source line.
    func back() {
        guard isActive, let script, cursor > 0 else { return }
        let line = lineOf(cursor)
        if let prevToken = script.tokens.last(where: { $0.line < line }) {
            let prevLine = prevToken.line
            cursor = script.tokens.firstIndex(where: { $0.line == prevLine }) ?? 0
        } else {
            cursor = 0
        }
        render()
    }

    // MARK: - Vision capture (Phase 4: camera → OCR → script)

    /// Capture the current camera view and OCR it into the scan buffer. Returns a spoken status.
    func scanPage() async -> String {
        guard let camera else { return "Camera unavailable — connect the glasses to scan a page." }
        // On-device OCR: the page never leaves, so the scope is an on-device one — but the still is
        // still requested through the chokepoint, so a later change of sink changes one word here.
        guard let data = await camera.filteredStill(for: .onDeviceVision,
                                                    source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.8) else {
            return "I couldn't capture the page. Point the glasses at it and try again."
        }
        return await ingestScannedImage(data)
    }

    /// OCR a captured page and append it to the scan buffer. Pure of the camera (the OCR is an
    /// injectable seam), so the scan→script flow is unit-testable. Returns a spoken status.
    @discardableResult
    func ingestScannedImage(_ data: Data) async -> String {
        guard let ocr else { return "Scanning isn't available right now." }
        let text = await ocr(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return "I couldn't read any text on that page. Try again with better lighting."
        }
        scanBuffer += (scanBuffer.isEmpty ? "" : "\n\n") + text
        scanPages += 1
        return "Captured page \(scanPages) (\(text.count) characters). Scan another page, or start the teleprompter."
    }

    func clearScan() {
        scanBuffer = ""
        scanPages = 0
    }

    /// Build a `TeleprompterScript` from the accumulated scan buffer (nil when empty).
    private func scannedScript(title: String?) -> TeleprompterScript? {
        let text = scanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let name = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? SavedScript.deriveTitle(from: text)
        return TeleprompterScript.parse(title: name, text: text)
    }

    /// Start prompting from the scanned pages, then clear the buffer. Returns false if nothing scanned.
    @discardableResult
    func startScannedScript(title: String? = nil, mode: PacingMode? = nil) -> Bool {
        guard let script = scannedScript(title: title) else { return false }
        start(script, mode: mode)
        clearScan()
        return true
    }

    /// Save the scanned pages as a stored script, then clear the buffer. Returns nil if nothing scanned.
    @discardableResult
    func saveScannedScript(title: String? = nil) -> SavedScript? {
        let text = scanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let saved = store.add(title: title ?? "", text: text)
        clearScan()
        return saved
    }

    // MARK: - Speed (live)

    /// "faster"/"slower": nudges WPM (auto-scroll) and, in audio-paced mode, also the
    /// aligner's responsiveness. Persists WPM so the Settings slider reflects it.
    func nudgeSpeed(faster: Bool) {
        pacing.nudgeWPM(faster ? 15 : -15)
        if mode == .audioPaced {
            pacing.setResponsiveness(pacing.responsiveness + (faster ? 0.1 : -0.1))
        }
        Config.setTeleprompterWPM(pacing.wpm)
        if mode == .autoScroll { restartAutoScrollTimer() }
        render()
    }

    func setWPM(_ value: Int) {
        pacing.setWPM(value)
        Config.setTeleprompterWPM(pacing.wpm)
        if mode == .autoScroll { restartAutoScrollTimer() }
        render()
    }

    func setLead(_ lines: Int) {
        pacing.setLead(lines)
        Config.setTeleprompterLead(pacing.leadLines)
        render()
    }

    // MARK: - Voice control

    /// Parse and apply a teleprompter control phrase. Returns true if it consumed the
    /// utterance (so the caller doesn't route it to the LLM). No-op when inactive.
    @discardableResult
    func handleVoiceCommand(_ text: String) -> Bool {
        guard isActive, let command = TeleprompterCommand.parse(text) else { return false }
        switch command {
        case .next: advance()
        case .back: back()
        case .pause: pause()
        case .resume: resume()
        case .restart: restart()
        case .stop: stop()
        case .faster: nudgeSpeed(faster: true)
        case .slower: nudgeSpeed(faster: false)
        }
        return true
    }

    // MARK: - Audio pacing (the headline)

    /// Feed a chunk of recognized speech to the aligner and advance the cursor to track it.
    /// Pure of audio/hardware — the live recognition callback and tests both call this.
    func ingestForPacing(_ text: String) {
        guard isActive, !isPaused, mode == .audioPaced, !normalizedTokens.isEmpty else { return }
        let heard = TeleprompterText.tokenize(text)
        guard !heard.isEmpty else { return }
        let tail = Array(heard.suffix(Self.maxHeardTail))
        let newCursor = ScriptAligner.advance(script: normalizedTokens, cursor: cursor,
                                              heard: tail, config: alignerConfig())
        guard newCursor != cursor else { return }
        cursor = newCursor
        render()
        checkCompletion()
    }

    /// Bias the aligner by the live responsiveness setting: more responsive looks a little
    /// further ahead and accepts a forward jump on less corroboration.
    private func alignerConfig() -> ScriptAligner.Config {
        var config = ScriptAligner.Config.default
        if pacing.responsiveness >= 0.66 {
            config.minSupportForJump = 1
            config.lookAhead = 16
        } else if pacing.responsiveness <= 0.34 {
            config.minSupportForJump = 3
            config.lookAhead = 8
        }
        return config
    }

    // MARK: - Auto-scroll

    /// Advance one word — driven by the auto-scroll timer (and called directly in tests).
    func autoScrollStep() {
        guard isActive, !isPaused, mode == .autoScroll, let script else { return }
        guard cursor < script.wordCount else { finish(); return }
        cursor += 1
        render()
        checkCompletion()
    }

    private func startAutoScroll() {
        stopAutoScroll()
        let timer = Timer.scheduledTimer(withTimeInterval: pacing.secondsPerWord, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoScrollStep() }
        }
        autoScrollTimer = timer
    }

    private func restartAutoScrollTimer() {
        if autoScrollTimer != nil { startAutoScroll() }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    // MARK: - Live recognition (device-pending shell)

    private func startRecognition() {
        // Only run when we have a shared audio source — keeps unit tests fully headless.
        guard let wakeWordService, let recognizer, recognizer.isAvailable else { return }
        stopRecognition()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        wakeWordService.addAudioBufferConsumer(id: Self.recognitionConsumerID) { [weak self] buffer in
            Task { @MainActor in self?.recognitionRequest?.append(buffer) }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isActive, self.mode == .audioPaced else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        // A deliberate control utterance ("faster", "pause") shouldn't move
                        // the cursor; otherwise treat it as reading and align on it.
                        if !self.handleVoiceCommand(text) { self.ingestForPacing(text) }
                        if self.isActive, self.mode == .audioPaced { self.startRecognition() }
                    } else {
                        self.ingestForPacing(text)
                    }
                }
                if let error {
                    let nsError = error as NSError
                    if nsError.code != 216, self.isActive, self.mode == .audioPaced {   // 216 = cancelled
                        self.restartRecognitionAfterDelay()
                    }
                }
            }
        }
    }

    private func restartRecognitionAfterDelay() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isActive, mode == .audioPaced { startRecognition() }
        }
    }

    private func stopRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        wakeWordService?.removeAudioBufferConsumer(id: Self.recognitionConsumerID)
    }

    // MARK: - Render

    private func render() {
        guard let script else { currentScreen = nil; return }
        let window = TeleprompterPaginator.window(script, cursor: displayCursor(), geometry: geometry)
        let prog = script.wordCount == 0 ? 1.0 : Double(min(max(cursor, 0), script.wordCount)) / Double(script.wordCount)
        progress = prog

        let controls = TeleprompterScreen.Controls(
            togglePause: { [weak self] in self?.togglePause() },
            slower: { [weak self] in self?.nudgeSpeed(faster: false) },
            faster: { [weak self] in self?.nudgeSpeed(faster: true) },
            stop: { [weak self] in self?.stop() }
        )
        let screen = TeleprompterScreen.build(title: script.title, window: window, progress: prog,
                                              wpm: pacing.wpm, isPaused: isPaused, controls: controls)
        currentScreen = screen
        glassesDisplay?.present(screen: screen) { [weak self] id in self?.handleSelection(id) }
    }

    private func togglePause() { isPaused ? resume() : pause() }

    private func handleSelection(_ id: String) {
        currentScreen?.items.first { $0.id == id }?.action()
    }

    private func checkCompletion() {
        guard let script, cursor >= script.wordCount, script.wordCount > 0 else { return }
        finish()
    }

    private func finish() {
        let title = script?.title ?? "Script"
        stop()
        glassesDisplay?.flash("✓ \(title) complete")
    }

    // MARK: - Cursor helpers

    /// The cursor shifted forward by the lead so the active line sits a touch ahead of the voice.
    private func displayCursor() -> Int {
        guard let script, pacing.leadLines > 0, !script.tokens.isEmpty else { return cursor }
        let targetLine = lineOf(cursor) + pacing.leadLines
        if let idx = script.tokens.firstIndex(where: { $0.line >= targetLine }) { return idx }
        return script.wordCount - 1
    }

    private func lineOf(_ index: Int) -> Int {
        guard let script, !script.tokens.isEmpty else { return 0 }
        let clamped = min(max(index, 0), script.tokens.count - 1)
        return script.tokens[clamped].line
    }
}
