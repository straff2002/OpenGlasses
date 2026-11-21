import Foundation
import Combine

/// Listens to live captions during a meeting, periodically asks an LLM for a running summary,
/// and posts lock screen notifications with it and suggested follow-up questions.
///
/// Each round sends the previous round's summary and the lines said since it (newest kept when
/// there are too many), never the whole transcript, so the prompt stays the same size however
/// long the meeting runs (`MeetingAnalysisWindow`). The first round, with no summary yet, asks
/// exactly what it always did.
///
/// Plan MO §2: the prompt and the delivery sit behind a `MeetingAnalysisSink`. A recording's
/// assistant (`start(captionService:llm:)`) uses `MeetingNotificationSink`, which asks and posts
/// exactly what this service did before; a live-hints lecture feeds its own finals
/// (`startFed(llm:sink:registry:)` and `ingest`) to `LectureKeyPointSink`.
@MainActor
class MeetingAssistantService: ObservableObject {
    @Published var isActive = false
    @Published var lastSummary: String = ""

    // MARK: - Private state

    /// Closure injected at start — avoids a hard dependency on LLMService.
    private var llm: ((String) async throws -> String)?

    /// Combine subscription to caption history.
    private var captionSubscription: AnyCancellable?

    /// What the next round sends: the previous summary, the lines since it, and a short tail of
    /// what came before them. Bounded, unlike the unbounded transcript this replaced.
    private(set) var window = MeetingAnalysisWindow()

    /// Position in the caption stream. Sequence-based, because `captionHistory` is capped and
    /// stops growing once full.
    private var cursor = CaptionCursor()

    /// Task managing the 60-second periodic trigger.
    private var timerTask: Task<Void, Never>?

    /// Prevents concurrent LLM calls.
    private var isAnalysing = false

    /// Resolves a diarized caption's speaker to the name the wearer gave it.
    private var registry: SpeakerRegistry?

    // MARK: - Public API

    /// Where the analysis goes and what it asks (Plan MO §2): a recording's notification, or a
    /// live-hints lecture's key point.
    private var sink: MeetingAnalysisSink?

    /// The analysis running now, if any. Tests await it.
    private(set) var analysisTask: Task<Void, Never>?

    /// The sink a recording's assistant uses: the running summary as a notification.
    static func makeRecordingSink() -> MeetingAnalysisSink { MeetingNotificationSink() }

    /// Start the assistant for a recording.
    /// - Parameters:
    ///   - captionService: The ambient caption service whose `captionHistory` is observed.
    ///   - llm: Async closure that sends a prompt to the LLM and returns the response text.
    func start(captionService: AmbientCaptionService, llm: @escaping (String) async throws -> String) {
        guard !isActive else { return }
        begin(llm: llm, sink: Self.makeRecordingSink(), registry: captionService.speakerRegistry)
        // Start from the present: anything already in the buffer predates this meeting.
        _ = cursor.take(newestFirst: captionService.captionHistory)

        // Subscribe to caption history changes.
        captionSubscription = captionService.$captionHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.handleCaptionUpdate(history)
            }
    }

    /// Start the assistant fed by its caller (Plan MO §2, a live-hints lecture): no caption
    /// subscription of its own; the caller hands each new final to `ingest`.
    func startFed(llm: @escaping (String) async throws -> String, sink: MeetingAnalysisSink,
                  registry: SpeakerRegistry? = nil) {
        guard !isActive else { return }
        begin(llm: llm, sink: sink, registry: registry)
    }

    private func begin(llm: @escaping (String) async throws -> String, sink: MeetingAnalysisSink,
                       registry: SpeakerRegistry?) {
        isActive = true
        self.llm = llm
        self.sink = sink
        self.registry = registry
        window = MeetingAnalysisWindow()
        cursor = CaptionCursor()
        isAnalysing = false
        lastSummary = ""

        // Periodic 60-second analysis trigger.
        timerTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 s
                guard let self, self.isActive else { break }
                await self.analyseIfNeeded(force: true)
            }
        }

        PrivacyLog.speech(.meetingNotes, .started)
    }

    /// Stop the assistant and clean up resources.
    func stop() {
        guard isActive else { return }
        isActive = false
        captionSubscription?.cancel()
        captionSubscription = nil
        timerTask?.cancel()
        timerTask = nil
        // An analysis already asked is not cancelled: its reply is delivered, as it always was.
        analysisTask = nil
        llm = nil
        sink = nil
        registry = nil
        PrivacyLog.speech(.meetingNotes, .stopped)
    }

    // MARK: - Caption ingestion

    /// Called whenever `captionHistory` publishes a new value.
    /// `captionHistory` is newest-first; we need entries we haven't seen yet.
    private func handleCaptionUpdate(_ history: [AmbientCaptionService.CaptionEntry]) {
        ingest(cursor.take(newestFirst: history))
    }

    /// New finals, oldest first. Analyses early once the buffer holds 100 words: a final ends at
    /// the recogniser's endpoint, so this is the pause after about 100 words.
    func ingest(_ newEntries: [AmbientCaptionService.CaptionEntry]) {
        guard isActive, !newEntries.isEmpty else { return }

        for entry in newEntries {
            window.append(Self.transcriptLine(for: entry, registry: registry))
        }

        // Trigger early if the buffer already has ≥ 100 words.
        if window.pendingWordCount >= 100, !isAnalysing {
            analysisTask = Task { await analyseIfNeeded(force: false) }
        }
    }

    /// What the transcript keeps for one caption: speaker-labelled when the caption was diarized
    /// and a registry is at hand, the bare text otherwise.
    static func transcriptLine(for entry: AmbientCaptionService.CaptionEntry,
                               registry: SpeakerRegistry?) -> String {
        guard let registry else { return entry.text }
        return entry.labeledText(registry: registry)
    }

    // MARK: - Analysis

    /// Run an LLM analysis unless one is already in progress.
    /// - Parameter force: When `true`, run even if the buffer has very few words.
    ///
    /// Nothing new since the last round, nothing asked: the old loop re-sent the whole transcript
    /// every 60 s whether anyone had spoken or not.
    private func analyseIfNeeded(force: Bool) async {
        guard isActive, !isAnalysing else { return }
        guard force || window.pendingWordCount >= 100 else { return }
        guard let llm, let sink, let round = window.nextRound() else { return }

        isAnalysing = true
        defer { isAnalysing = false }

        let prompt = sink.prompt(for: round)

        do {
            let response = try await llm(prompt)
            // The lines this round covered become the past; the reply is the next round's summary.
            window.complete(round, reply: response)
            lastSummary = response
            sink.deliver(response)
            PrivacyLog.speech(.meetingNotes, .analysisCompleted, characters: response.count)
        } catch {
            PrivacyLog.model(.requestFailed, detail: PrivacyToken("meetingSummary"),
                             error: SafeErrorSummary(error))
        }
    }
}
