import Combine
import Foundation
import UIKit

/// Drives a live reading session (docs/plans/BT-reading-companion.md P2): glasses frames →
/// `PageTurnDetector` → OCR → `ReadingSessionStore`, plus the session's spoken bookends and the
/// grounding context each turn is answered from.
///
/// Every collaborator is an injected seam (OCR, deck generation, note + brain writes, the clock),
/// so the whole flow is unit-testable without a camera, a model, or a database — the same shape
/// `StudyService` uses.
@MainActor
final class ReadingCompanionService: ObservableObject {
    static let shared = ReadingCompanionService()

    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var activeSessionID: String?

    /// Derived, not stored — the store's pages are the single source of truth, so the spoken
    /// status can never disagree with the corpus (review finding: the stored copy was an
    /// invariant every future page-mutating path would have had to remember).
    var pagesThisSession: Int { activeSession?.pages.count ?? 0 }

    /// Captures the detector called settled but OCR couldn't read. The number to watch on the P3
    /// device pass: a high count against a real book means the OCR/threshold tuning is off, not
    /// that the reader stopped turning pages.
    private(set) var unreadableCaptures = 0

    /// The shared camera stream stopped mid-session (glasses disconnect, another feature's
    /// teardown) and a restart attempt failed. Surfaced in status/end lines so the reader learns
    /// pages are being missed instead of hearing a confident page count.
    private(set) var streamInterrupted = false

    var store: ReadingSessionStore = .shared
    weak var presence: PresenceMonitor?
    /// In-lens recap card (P3). All display calls are safe no-ops without display hardware.
    weak var glassesDisplay: GlassesDisplayService?
    private weak var camera: CameraService?

    /// Frame → recognized text. Set by `configure(...)`; tests inject a fake.
    var ocr: ((UIImage) async -> String)?
    /// (systemPrompt, text, source) → deck. Set by `configure(...)`; tests inject a fake.
    var generateDeck: ((String, String, String) async -> StudyDeck?)?
    /// (content, tags) → saved note.
    var saveNote: ((String, [String]) -> Void)?
    /// A one-line fact about the reader's activity — never page content. See `end()`.
    var ingestBrainFact: ((String, String) -> Void)?
    /// Whether another feature (recording, broadcast, a live session) is consuming the camera
    /// stream right now. Configured by AppState; gates whether `end()` may stop a stream this
    /// service started. Default `false` = safe to stop only what we started.
    var otherStreamConsumersActive: () -> Bool = { false }

    /// The deck build kicked off by `end()`. Runs off the tool's critical path — the router's 30s
    /// tool timeout must never eat the spoken recap because an LLM was slow. Exposed so tests (and
    /// a future UI spinner) can await completion.
    private(set) var deckGenerationTask: Task<Void, Never>?

    /// documentId → the reference copy's full text (P4). Set by `configure(...)` to
    /// `DocumentStore.fullText`; tests inject a fake.
    var loadReferenceText: ((String) -> String?)?

    /// Builds the page detector for each session. `configure(...)` points this at the Config
    /// knobs (P3 device-pass tuning is then data-only); tests keep the deterministic default.
    var makeDetector: () -> PageTurnDetector = { PageTurnDetector() }

    /// Injected clock — deterministic in tests.
    var clock: () -> Date = { Date() }
    /// Ceiling on the injected reading block. Sized for the on-device model, which is the tighter
    /// of the two budgets.
    var contextBudgetCharacters = 6000
    /// Floor on the gap between two evaluated frames. The camera runs far faster than pages turn,
    /// so this is the main battery lever: everything upstream of it is skipped, hashing included.
    var minimumFrameInterval: TimeInterval = 0.5

    private var detector = PageTurnDetector()
    /// The active book's reference index (P4), built off-main at session start when a copy is
    /// attached. Pages captured before it's ready simply stay unaligned — raw OCR grounding,
    /// exactly as without a reference.
    private var alignmentIndex: BookAlignmentIndex?
    /// Exposed so tests (and a future UI spinner) can await index readiness.
    private(set) var alignmentPreparation: Task<Void, Never>?
    private var frameSubscription: AnyCancellable?
    private var streamStateSubscription: AnyCancellable?
    /// True when this session was the one that turned the camera stream on — `end()` then turns
    /// it back off (unless someone else is consuming it), mirroring the photo path's
    /// capture-then-restore bookkeeping. Leaving it running drained the glasses indefinitely.
    private var startedStream = false
    private var lastEvaluatedAt: TimeInterval?
    /// Serializes OCR — not redundant with the detector's once-per-page guarantee. Without it a
    /// page settling while the previous capture's OCR is still running could finish out of order,
    /// and `appendPage` assigns `pageIndex` at completion time. A settle skipped while capturing
    /// isn't lost: the gate re-detects the new page as a change on the next evaluated frame.
    private var capturing = false

    init() {}

    /// No TTS seam here on purpose: every entry point returns its line to `ReadingSessionTool`, and
    /// the assistant speaks tool results already. A `speak` closure would be a second, silent path
    /// to the same speaker.
    func configure(camera: CameraService, study: StudyService, documents: DocumentStore? = nil) {
        self.camera = camera
        self.ocr = { image in
            guard let cg = image.cgImage else { return "" }
            return await OCRService().recognizeText(in: cg).text
        }
        self.loadReferenceText = { [weak documents] documentId in
            documents?.fullText(documentId: documentId)
        }
        // The detector reads the Config knobs per session (P3): the device pass retunes with
        // `defaults write`, not a rebuild. Tests never call configure, keeping the fixed defaults.
        self.makeDetector = {
            PageTurnDetector(
                gate: FrameGate(hammingThreshold: Config.readingHammingThreshold,
                                heartbeat: 0, adaptiveEnabled: false),
                stabilityWindow: Config.readingStabilityWindowSeconds)
        }
        self.minimumFrameInterval = Config.readingMinimumFrameInterval
        self.generateDeck = { [weak study] systemPrompt, text, source in
            try? await study?.makeDeck(fromText: text, source: source, systemPrompt: systemPrompt)
        }
        self.saveNote = { content, tags in
            ContextualNoteStore.shared.save(ContextualNote(
                id: UUID().uuidString, content: content, tags: tags,
                latitude: nil, longitude: nil, locationName: nil, createdAt: Date()))
        }
        self.ingestBrainFact = { fact, book in
            BrainStore.shared.ingest(text: fact, sourceRef: book, sourceKind: "book", origin: .fromScan)
        }
    }

    var activeSession: ReadingSession? {
        activeSessionID.flatMap { store.session(id: $0) }
    }

    // MARK: - Lifecycle

    /// Start reading `bookTitle`. Returns what to say: the "where was I?" recap when this book has
    /// history, an opening line when it doesn't — or why the session could not start.
    @discardableResult
    func start(bookID: String, bookTitle: String) async -> String {
        guard !isActive else { return "Already reading \(activeSession?.bookTitle ?? bookTitle)." }
        // Belt and braces with the registry's hipaaDisabledTools filter: passive camera OCR of
        // whatever is in front of the wearer has no place in compliance mode, whichever path asks.
        guard !Config.hipaaMode else {
            return "The reading companion is disabled while medical compliance mode is on."
        }

        // Camera before session: a session that can never receive a frame must not open, and the
        // failure has to reach the reader's ears — swallowing it here meant "I'll follow along"
        // followed an hour later by "I didn't catch any pages" with no why.
        if let camera, !camera.isStreaming {
            do {
                try await camera.startStreaming()
                startedStream = true
            } catch {
                return "I couldn't start the camera — \(error.localizedDescription) Check the glasses and try again."
            }
        } else {
            startedStream = false
        }

        // A known book keeps its shelf title: "start reading Hobbit" resolving to "The Hobbit"
        // must not quietly rename the book to the spoken shorthand.
        let title = store.books().first { $0.id == bookID }?.title ?? bookTitle

        // Recap *before* opening the new session, or the session we just created would count itself
        // in "across N sittings" and the reader would hear a sitting they haven't had yet.
        let recap = store.stats(forBook: bookID).flatMap { stats in
            ReadingRecapBuilder.resumeRecap(
                stats: stats, lastPageText: store.pages(forBook: bookID).last?.text,
                progress: store.progress(forBook: bookID))
        }
        showRecapCard(forBook: bookID)

        prepareAlignment(forBook: bookID)
        let session = store.startSession(bookID: bookID, bookTitle: title, at: clock())
        activeSessionID = session.id
        unreadableCaptures = 0
        streamInterrupted = false
        isActive = true
        isPaused = false
        detector = makeDetector()
        lastEvaluatedAt = nil

        subscribeToFrames()
        return recap ?? "Reading \(title). I'll follow along."
    }

    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        // Keep the subscription: pause is a short interruption, and re-subscribing would make the
        // next frame look like the session's first, re-capturing the page already on the table.
    }

    func resume() {
        guard isActive else { return }
        // Resume also serves as the reader's "camera is back, pick it up" after an interruption —
        // the status line points them here, so it must work when not paused too.
        guard isPaused || streamInterrupted else { return }
        isPaused = false
        // The book may have moved while we weren't watching, so treat what's in front of us as new.
        detector.reset()
        lastEvaluatedAt = nil
        // If the stream died while paused (disconnect, another feature's teardown), resuming is
        // the reader asking for it back.
        if let camera, !camera.isStreaming {
            Task { @MainActor in await self.restartStream() }
        }
    }

    /// End the session: recap returned for speaking, note saved, deck build kicked off in the
    /// background from *this sitting's* pages.
    ///
    /// Everything on this path is deterministic and fast on purpose: the tool router times a tool
    /// call out at 30s, and awaiting an LLM deck generation here (as this originally did) meant a
    /// slow model ate the recap and — because state was already torn down — a retried "end"
    /// answered "no session running". The deck is the one artifact that may lag; the recap never.
    @discardableResult
    func end() async -> String {
        guard isActive, let sessionID = activeSessionID else { return "No reading session is running." }

        frameSubscription?.cancel()
        frameSubscription = nil
        streamStateSubscription?.cancel()
        streamStateSubscription = nil
        alignmentPreparation?.cancel()
        alignmentPreparation = nil
        // Kept past teardown so this sitting's deck builds from canonical slices (P4).
        let reference = alignmentIndex
        alignmentIndex = nil
        store.endSession(id: sessionID, at: clock())
        isActive = false
        isPaused = false
        activeSessionID = nil
        let wasInterrupted = streamInterrupted
        streamInterrupted = false

        // Give the camera back the way we found it (the photo path's capture-then-restore
        // precedent): stop only a stream this session started, and only when nothing else is
        // consuming it — otherwise the glasses stream HEVC indefinitely after "I'm done reading".
        if startedStream, let camera, camera.isStreaming, !otherStreamConsumersActive() {
            await camera.stopStreaming()
        }
        startedStream = false

        guard let session = store.session(id: sessionID), !session.pages.isEmpty else {
            return wasInterrupted
                ? "Reading session ended — the camera dropped out during it, so I didn't catch any pages."
                : "Reading session ended — I didn't catch any pages."
        }

        var recap = ReadingRecapBuilder.sessionRecap(session: session, overview: nil)
            ?? "Reading session ended."
        if wasInterrupted {
            recap += " Heads up: the camera dropped out during this sitting, so some pages may be missing."
        }

        saveNote?(recap, ["reading", session.bookTitle])

        // Only the *activity* reaches the brain, never the prose. The brain is a graph of the
        // reader's own life — "who works at Acme", "when did I last see Alice" — and its extractor
        // can't tell a novel's characters from real people, so ingesting pages would file Bilbo
        // alongside the reader's colleagues. What's true and worth keeping is that they read this.
        ingestBrainFact?("Read \(session.pages.count) page(s) of \(session.bookTitle).",
                         session.bookTitle)

        if let text = ReadingRecapBuilder.deckSource(session: session, reference: reference), let generateDeck {
            let systemPrompt = ReadingRecapBuilder.deckSystemPrompt(bookTitle: session.bookTitle)
            let source = "Reading: \(session.bookTitle)"
            deckGenerationTask = Task {
                // StudyService.makeDeck saves the deck itself; failure just means no deck, which
                // Study Mode's list reflects honestly.
                _ = await generateDeck(systemPrompt, text, source)
            }
            recap += " I'm building a study deck from this sitting — it'll be in Study Mode shortly."
        }
        return recap
    }

    // MARK: - Reference alignment (P4)

    /// Build the alignment index off-main when this book has a copy attached. Pages captured
    /// before it's ready stay unaligned — raw OCR grounding, exactly as without a reference.
    private func prepareAlignment(forBook bookID: String) {
        alignmentIndex = nil
        alignmentPreparation = nil
        guard let reference = store.reference(forBook: bookID),
              let text = loadReferenceText?(reference.documentId), !text.isEmpty else { return }
        alignmentPreparation = Task { [weak self] in
            // Index construction is pure CPU over the whole book — off the main actor.
            let index = await Task.detached(priority: .utility) { BookAlignmentIndex(text: text) }.value
            guard let self, !Task.isCancelled else { return }
            // Only the session that asked for it may install it.
            guard self.isActive, self.activeSession?.bookID == bookID else { return }
            self.alignmentIndex = index
        }
    }

    // MARK: - HUD (P3)

    /// Flash the recap card on the in-lens display. Transient by design: it flashes over whatever
    /// card is held (Now/Next, launcher) and the display restores itself — reading never manages
    /// display state. Safe no-op without display hardware or with the HUD disabled.
    private func showRecapCard(forBook bookID: String) {
        guard let glassesDisplay, let stats = store.stats(forBook: bookID) else { return }
        let streak = ReadingStreaks.current(
            sessionDates: store.sessions(forBook: bookID).map(\.startedAt), today: clock())
        guard let content = ReadingHUDCard.notification(
            stats: stats, progress: store.progress(forBook: bookID), streak: streak) else { return }
        glassesDisplay.showNotification(title: content.title, body: content.body, icon: .info, duration: 6)
    }

    // MARK: - Q&A

    /// "Where was I?" — answerable any time, without a live session.
    func whereWasI(bookID: String? = nil) -> String? {
        let book = bookID ?? activeSession?.bookID ?? store.books().first?.id
        guard let book, let stats = store.stats(forBook: book) else { return nil }
        showRecapCard(forBook: book)
        return ReadingRecapBuilder.resumeRecap(
            stats: stats, lastPageText: store.pages(forBook: book).last?.text,
            progress: store.progress(forBook: book))
    }

    /// The grounding block for this turn, or `nil` when no session is live — the house
    /// `promptContext()` shape, injected unconditionally by `buildSystemPrompt` alongside the
    /// field-assist vault and active-project blocks.
    ///
    /// Deliberately *not* behind a classifier keyword list: a question mid-book is "who is she?" or
    /// "why did he do that?", which matches no keyword. The live session is the signal, and this
    /// nil is what gates it — the same reasoning the playbook context already runs on. Injecting at
    /// `buildSystemPrompt` also means local, cloud and cloud-agent paths are covered by one line,
    /// where a threaded parameter would inherit the two paths that silently drop `weatherContext`.
    func promptContext(turn: String? = nil) -> String? {
        guard isActive, let session = activeSession else { return nil }
        return ReadingContextBuilder.block(
            bookTitle: session.bookTitle,
            pages: store.pages(forBook: session.bookID),
            budgetCharacters: contextBudgetCharacters,
            reference: alignmentIndex,
            assertedReadUpTo: store.reference(forBook: session.bookID)?.assertedReadUpTo,
            retrievalRanges: store.coveredRanges(forBook: session.bookID),
            unconfirmedGap: store.unconfirmedGap(forBook: session.bookID),
            turn: turn)
    }

    /// "I've read up to here" — count everything before the current camera-proven position as
    /// read (P4 catch-up: started the app mid-book, or read offline between sittings). Returns
    /// the spoken confirmation or the reason it couldn't be recorded.
    func assertCaughtUp(bookID: String? = nil) -> String {
        guard let book = bookID ?? activeSession?.bookID ?? store.books().first?.id else {
            return "I don't have a book on the shelf yet — say \"start reading\" with the title first."
        }
        guard store.reference(forBook: book) != nil else {
            return "That works once a copy of the book is attached — add one under Settings → Reading."
        }
        guard store.assertCaughtUp(forBook: book) != nil else {
            return "Let me see a page first so I know where you are, then say that again."
        }
        if let progress = store.progress(forBook: book) {
            let percent = min(100, max(1, Int((progress * 100).rounded())))
            return "Got it — everything up to here counts as read. That's about \(percent)% of the book."
        }
        return "Got it — everything up to here counts as read."
    }

    // MARK: - Book identity

    /// Resolve a spoken title against the books already on the shelf, so "Hobbit" continues
    /// "The Hobbit" instead of forking a second corpus (and denying "where was I?" history the
    /// store actually has). Exact slug first; then equality with leading articles stripped —
    /// deliberately no substring matching, which would collapse "Dune" into "Dune Messiah".
    /// A genuinely new title becomes a new book.
    func resolveBookID(forSpokenTitle title: String) -> String {
        let slug = ReadingBookID.make(from: title)
        let known = store.books().map(\.id)
        if known.contains(slug) { return slug }
        let stripped = Self.articleStripped(slug)
        if let match = known.first(where: { Self.articleStripped($0) == stripped }) { return match }
        return slug
    }

    private static func articleStripped(_ slug: String) -> String {
        for article in ["the-", "a-", "an-"] where slug.hasPrefix(article) {
            return String(slug.dropFirst(article.count))
        }
        return slug
    }

    // MARK: - Frames

    private func subscribeToFrames() {
        guard let camera else { return }
        frameSubscription = camera.framePublisher.sink { [weak self] image in
            Task { @MainActor in self?.handleFrame(image) }
        }
        // The shared stream can be stopped underneath us — glasses disconnect, another feature's
        // teardown, a failed stall recovery. Without this, the session stayed "active" while every
        // subsequent page was silently lost. Try one restart; if the camera stays down, mark the
        // session interrupted so status/end say so.
        streamStateSubscription = camera.$isStreaming
            .removeDuplicates()
            .sink { [weak self] streaming in
                guard let self, self.isActive, !streaming else { return }
                Task { @MainActor in await self.restartStream() }
            }
    }

    private func restartStream() async {
        guard isActive, let camera, !camera.isStreaming else { return }
        do {
            try await camera.startStreaming()
            startedStream = true
            streamInterrupted = false
            // The scene may have changed while we were dark — re-settle whatever is there now.
            detector.reset()
            lastEvaluatedAt = nil
        } catch {
            streamInterrupted = true
        }
    }

    /// Exposed for tests — the live path arrives here from the camera subscription.
    func handleFrame(_ image: UIImage) {
        guard isActive, !isPaused, !capturing else { return }
        // A reader is motionless and silent, which reads as `.idle` — the exact false negative
        // `CaptionPresenceGate` exists for. Only `.away` (disconnected or backgrounded, so there
        // are no frames anyway) justifies dropping out.
        if let presence, CaptionPresenceGate.shouldSuspend(mode: presence.mode) { return }

        let now = clock().timeIntervalSinceReferenceDate
        if let last = lastEvaluatedAt, now - last < minimumFrameInterval { return }
        lastEvaluatedAt = now

        guard let hash = PerceptualHash.dhash(image) else { return }
        guard case .pageSettled = detector.evaluate(hash: hash, now: now) else { return }
        capturePage(image, hash: hash)
    }

    private func capturePage(_ image: UIImage, hash: UInt64) {
        guard let sessionID = activeSessionID, let ocr else { return }
        capturing = true
        let capturedAt = clock()
        Task { @MainActor in
            defer { capturing = false }
            let text = await ocr(image).trimmingCharacters(in: .whitespacesAndNewlines)
            // The session can end mid-OCR — don't file a page against a session that's over.
            guard isActive, activeSessionID == sessionID else { return }
            guard !text.isEmpty else {
                // A settled view we couldn't read is not a page the reader read. Filing it would
                // put a wall or a glare-blown page into their page count and wreck the pace stats,
                // and it grounds nothing either way.
                unreadableCaptures += 1
                return
            }
            // Locate the capture in the reference copy when one is attached (P4). Alignment is
            // best-effort: a miss just means this page grounds on its raw OCR.
            let alignment = alignmentIndex?.align(captureText: text)
            store.appendPage(text: text, dHash: hash, at: capturedAt, to: sessionID,
                             alignment: alignment)
        }
    }
}
