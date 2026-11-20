import AVFoundation
import Combine
import Foundation

// The production carriers for `LiveHintsService` (Plan MO P1). Each is a thin adapter over a
// service the app already has; the decisions are in the session and the pure core.

// MARK: - Documents

/// The active project's documents (Plan AN), searched on the phone.
@MainActor
final class DocumentStoreHintSearch: HintDocumentSearch {
    private let store: DocumentStore
    /// The session's scope: the active project's namespace, "global" for the unscoped default.
    private let namespace: () -> String

    init(store: DocumentStore, namespace: @escaping () -> String) {
        self.store = store
        self.namespace = namespace
    }

    func passages(for question: String, limit: Int) -> [HintPassage] {
        store.query(question, limit: limit, namespace: namespace()).map(HintPassage.init)
    }

    func documentTitles() -> [String] {
        store.list(namespace: namespace()).map(\.name)
    }
}

// MARK: - The model

/// One stateless, tool-free completion through `LLMService` (§5 step 3): the provider the wearer
/// chose, with HIPAA mode and Medical Local Only applied exactly as for a Direct turn
/// (`completeStateless` resolves the model through the same medical routing rule), and nothing of it
/// left in the conversation.
@MainActor
final class LLMServiceHintModel: HintModel {
    private let llm: LLMService
    private let isOnline: () -> Bool

    init(llm: LLMService, isOnline: @escaping () -> Bool) {
        self.llm = llm
        self.isOnline = isOnline
    }

    /// A model is configured, and either the network is up or the model is on the phone.
    var isAvailable: Bool {
        guard let model = Config.activeModel else { return false }
        return isOnline() || Self.runsOnPhone(model.llmProvider)
    }

    nonisolated static func runsOnPhone(_ provider: LLMProvider) -> Bool {
        provider == .local || provider == .appleOnDevice
    }

    func complete(system: String, user: String) async throws -> String {
        let llm = self.llm
        // Off-turn, as the meeting assistant's calls are: it runs alongside whatever the wearer says.
        return try await TurnRecorder.offTurn { try await llm.completeStateless(user, system: system) }
    }
}

// MARK: - The lens

/// The glasses' Display, through the answer-card path (§6): the hint's pages go up with
/// `presentAnswerCard(_:wearerLed: false)`, so a lens the wearer dismissed stays dismissed, and page
/// with `turnAnswerCard`, under the same stale-press gate as an answer.
@MainActor
final class GlassesHintLens: HintLensSink {
    private let display: GlassesDisplayService
    private let answerCard: HUDAnswerCard
    private var shown: (id: Int, pages: [HUDScreen], index: Int)?

    init(display: GlassesDisplayService, answerCard: HUDAnswerCard) {
        self.display = display
        self.answerCard = answerCard
    }

    var isAvailable: Bool {
        Config.glassesDisplayEnabled && display.deviceSupportsDisplay() && display.acceptsAnswerCard
    }

    func present(_ hint: LiveHint) -> Bool {
        let pages = HintLensCardBuilder.pages(for: hint, geometry: HUDAnswerCard.activeGeometry(),
                                              suggestion: Config.hipaaMode) { [weak self] action in
            self?.handle(action, hintID: hint.id)
        }
        guard !pages.isEmpty else { return false }
        // The assistant's own answer card gives way, as it does to a new answer; it can still be
        // brought back by voice ("show that again").
        if answerCard.isHeld, !answerCard.answer.isEmpty { answerCard.close() }
        let index = shown?.id == hint.id ? min(shown?.index ?? 0, pages.count - 1) : 0
        guard display.presentAnswerCard(pages[index], wearerLed: false, onSelect: selectionHandler) else {
            if shown?.id == hint.id { shown = nil }
            return false
        }
        shown = (hint.id, pages, index)
        return true
    }

    func hide(hintID: Int) {
        guard let shown, shown.id == hintID else { return }
        self.shown = nil
        guard display.heldAnswerCardSerial == HintLensCardBuilder.cardSerialBase + hintID else { return }
        display.endInteractive()
    }

    private var selectionHandler: (String) -> Void {
        { [weak self] id in
            guard let self, let shown = self.shown, shown.pages.indices.contains(shown.index) else { return }
            shown.pages[shown.index].items.first { $0.id == id }?.action()
        }
    }

    private func handle(_ action: HintLensCardBuilder.Action, hintID: Int) {
        guard let current = shown, current.id == hintID else { return }
        switch action {
        case .next, .back:
            let target = action == .next ? current.index + 1 : current.index - 1
            guard current.pages.indices.contains(target) else { return }
            if display.turnAnswerCard(to: current.pages[target], issuedAgainst: display.heldScreenRevision,
                                      onSelect: selectionHandler) {
                shown = (current.id, current.pages, target)
            }
        case .close:
            hide(hintID: hintID)
        }
    }
}

// MARK: - The ear

/// Whether an output route is the phone's own speaker (§6: never there).
enum HintOutputRoute {
    /// True when nothing but the phone's built-in speaker or receiver is the output. An empty route
    /// counts as the phone: nothing private is there to speak into.
    static func isPhoneSpeaker(outputs: [AVAudioSession.Port]) -> Bool {
        outputs.allSatisfy { $0 == .builtInSpeaker || $0 == .builtInReceiver }
    }
}

/// The assistant's voice for a hint (§6): `TextToSpeechService` over the idle session as it stands
/// (no conversation mic taken, other audio ducked by the session's shape, never moved to the
/// loudspeaker), on the phone's own voices, and not mirrored to the lens.
@MainActor
final class TTSHintEar: HintEarSink {
    private let tts: TextToSpeechService
    var onRouteChanged: ((Bool) -> Void)?
    var onFinishedSpeaking: (() -> Void)?
    private var generation = 0
    private var speakingHint = false
    private var routeObserver: NSObjectProtocol?

    init(tts: TextToSpeechService) {
        self.tts = tts
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onRouteChanged?(self.isPhoneSpeaker)
            }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    var isPhoneSpeaker: Bool {
        HintOutputRoute.isPhoneSpeaker(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }

    func sayHint(_ text: String) {
        generation += 1
        let mine = generation
        // The assistant answering the wearer is never cut short for a hint: speaking would replace
        // it. The hint stays on the phone and can be repeated.
        if tts.isSpeaking, !speakingHint {
            PrivacyLog.speech(.liveHints, .hintSkipped, detail: PrivacyToken("ear-assistantSpeaking"))
            Task { @MainActor [weak self] in
                guard let self, mine == self.generation else { return }
                self.onFinishedSpeaking?()
            }
            return
        }
        speakingHint = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            // On the phone's voices: a hint has to start inside two seconds, and the room's words
            // stay off another server for it.
            _ = await self.tts.speakReporting(text, source: .hint, mirrorToHUD: false, onDeviceOnly: true,
                                              takesConversationRoute: false)
            guard mine == self.generation else { return }
            self.speakingHint = false
            self.onFinishedSpeaking?()
        }
    }

    func stopSpeaking() {
        // Only a hint of ours: an answer the assistant is giving is not the session's to cut.
        guard speakingHint else { return }
        speakingHint = false
        generation += 1
        tts.stopSpeaking()
    }

    func chime() {
        guard !isPhoneSpeaker, !tts.isSpeaking else { return }
        tts.playTone(frequency: 1_320, duration: 0.06)
    }
}

// MARK: - Speech activity

/// The ungated mic level (§6), from a consumer of its own on the shared tap. The caption consumers
/// are gated against the assistant's voice; this one is not, so a person talking over a hint is
/// heard.
@MainActor
final class MicLevelHintVoiceActivity: HintVoiceActivitySource {
    static let consumerId = "live_hints_level"
    private weak var wakeWordService: WakeWordService?

    init(wakeWordService: WakeWordService) {
        self.wakeWordService = wakeWordService
    }

    func start(onChange: @escaping (Bool) -> Void) {
        let meter = HintMicLevelMeter { isSpeaking in onChange(isSpeaking) }
        wakeWordService?.addAudioBufferConsumer(id: Self.consumerId) { buffer in meter.feed(buffer) }
    }

    func stop() {
        wakeWordService?.removeAudioBufferConsumer(id: Self.consumerId)
    }
}

// MARK: - Captions

/// `AmbientCaptionService` as the session's captions.
@MainActor
final class AmbientCaptionHintSource: HintCaptionSource {
    private let service: AmbientCaptionService
    private var subscription: AnyCancellable?
    var onHistoryChanged: (() -> Void)?

    init(service: AmbientCaptionService) {
        self.service = service
        subscription = service.$captionHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onHistoryChanged?() }
    }

    var isActive: Bool { service.isActive }
    var captionHistory: [AmbientCaptionService.CaptionEntry] { service.captionHistory }

    /// The language the captions are written in: the wearer's language for translated captions,
    /// the recognition language otherwise.
    var languageCode: String {
        service.translationActive ? Config.translationWearerLanguage : SpeechLocaleResolver.current.identifier
    }

    var contextualStrings: [String] {
        get { service.sessionContextualStrings }
        set { service.sessionContextualStrings = newValue }
    }

    func start() { service.start() }
    func stop() { service.stop() }
}

// MARK: - The clock

@MainActor
final class SystemHintClock: HintClock {
    init() {}

    var now: Date { Date() }

    func repeating(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                tick()
            }
        }
        return { task.cancel() }
    }
}
