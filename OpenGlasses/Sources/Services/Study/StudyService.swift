import Foundation
import Combine

enum StudyServiceError: Error, LocalizedError {
    case notConfigured
    case generationFailed
    case noDocument

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Study Mode isn't configured."
        case .generationFailed: return "Couldn't generate study material from that content."
        case .noDocument: return "I couldn't find that document."
        }
    }
}

/// Drives Study Mode end to end (docs/plans/study-mode.md): generate a deck from document text via the
/// structured text→JSON LLM call, persist it, and run hands-free quiz / flashcard-review sessions. The
/// LLM call, document source, store, and clock are injectable seams so the flow is unit-testable.
@MainActor
final class StudyService: ObservableObject {
    static let shared = StudyService()

    var store: StudyStore = .shared
    /// (systemPrompt, userText, jsonSchema) → JSON object. Set by `configure(...)`; tests inject a fake.
    var generate: ((String, String, [String: Any]) async -> [String: Any]?)?
    weak var documentStore: DocumentStore?
    /// The still source, typed as the privacy chokepoint (W04.1). Scanning is on-device OCR, so
    /// the scope is an on-device one — but it is still requested through the accessor, so the
    /// classification is written at the call site instead of inferred from a missing filter call.
    weak var camera: (any FilteredStillProviding)?
    /// JPEG → recognized text (OCR). Set by `configure(...)`; tests inject a fake.
    var ocr: ((Data) async -> String)?

    /// Accumulated text from hands-free scanning (one or more pages) for the next deck.
    @Published private(set) var scanBuffer: String = ""
    @Published private(set) var scanPages: Int = 0
    var hasScannedPages: Bool { scanPages > 0 }

    private let grader = QuizGrader()
    var spaced = SpacedRepetition()
    /// Injected clock (seconds since reference date) — deterministic in tests.
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    @Published private(set) var quizSession: QuizSession?
    @Published private(set) var reviewSession: ReviewSession?

    struct QuizSession: Equatable { let deckID: String; let questions: [QuizQuestion]; var index: Int; var answers: [String: String] }
    struct ReviewSession: Equatable { let deckID: String; let cards: [Flashcard]; var index: Int; var showingBack: Bool }

    init() {}

    func configure(llm: LLMService, documentStore: DocumentStore?, tts: TextToSpeechService,
                   camera: (any FilteredStillProviding)? = nil) {
        self.documentStore = documentStore
        self.camera = camera
        self.generate = { [weak llm] systemPrompt, userText, jsonSchema in
            await llm?.completeStructured(systemPrompt: systemPrompt, userText: userText, jsonSchema: jsonSchema)
        }
        self.ocr = { data in await OCRService().recognizeText(in: data).text }
    }

    // MARK: - Hands-free scan source (glasses camera → OCR → text)

    /// OCR a captured page and append it to the scan buffer. Returns a spoken status.
    func ingestScannedImage(_ data: Data) async -> String {
        guard let ocr else { return "Scanning isn't available right now." }
        let text = await ocr(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "I couldn't read any text on that page. Try again with better lighting." }
        scanBuffer += (scanBuffer.isEmpty ? "" : "\n\n") + text
        scanPages += 1
        return "Captured page \(scanPages) (\(text.count) characters). Say \"scan\" for another page, or \"make deck\" to build."
    }

    /// Capture the current camera frame and ingest it.
    func scanPage() async -> String {
        guard let camera else { return "Camera unavailable — connect the glasses or use the phone camera." }
        guard let data = await camera.filteredStill(for: .onDeviceVision,
                                                    source: .cachedFrameThenPhoto)
            .jpegData(compressionQuality: 0.8) else {
            return "I couldn't capture the page. Point the glasses at it and try again."
        }
        return await ingestScannedImage(data)
    }

    /// Build a deck from the accumulated scan buffer, then clear it.
    func makeDeckFromScan() async throws -> StudyDeck {
        let text = scanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw StudyServiceError.noDocument }
        let deck = try await makeDeck(fromText: text, source: "Scanned notes")
        clearScan()
        return deck
    }

    func clearScan() {
        scanBuffer = ""
        scanPages = 0
    }

    // MARK: - Generation

    /// `systemPrompt` overrides the default generation instructions — the reading companion (Plan
    /// BT) passes one that scopes the model to the session's pages, since a model that recognises
    /// the book will otherwise happily quiz the reader on chapters they haven't reached.
    func makeDeck(fromText text: String, source: String?, systemPrompt: String? = nil) async throws -> StudyDeck {
        guard let generate else { throw StudyServiceError.notConfigured }
        guard let json = await generate(systemPrompt ?? StudyContentBuilder.systemPrompt(),
                                        StudyContentBuilder.userText(forContent: text),
                                        StudyContentBuilder.jsonSchema()) else {
            throw StudyServiceError.generationFailed
        }
        let deck = try StudyContentBuilder.parse(json, source: source)
        store.saveDeck(deck)
        return deck
    }

    func makeDeck(fromDocument query: String) async throws -> StudyDeck {
        guard let documentStore else { throw StudyServiceError.noDocument }
        let q = query.lowercased()
        guard let ref = documentStore.list().first(where: { $0.id == query || $0.name.lowercased().contains(q) }) else {
            throw StudyServiceError.noDocument
        }
        let text = documentStore.query(ref.name, limit: 40, namespace: nil, documentIds: [ref.id])
            .map(\.text).joined(separator: "\n\n")
        guard !text.isEmpty else { throw StudyServiceError.noDocument }
        return try await makeDeck(fromText: text, source: ref.name)
    }

    // MARK: - Quiz flow

    /// Start a quiz; returns the first question text, or nil if the deck has no quiz.
    func startQuiz(deckID: String) -> String? {
        guard let deck = store.deck(id: deckID), !deck.quiz.isEmpty else { return nil }
        quizSession = QuizSession(deckID: deckID, questions: deck.quiz, index: 0, answers: [:])
        return questionText(deck.quiz[0], number: 1, total: deck.quiz.count)
    }

    func answerQuiz(_ spoken: String) -> String {
        guard var session = quizSession else { return "No quiz in progress. Say \"quiz me\" to start." }
        let question = session.questions[session.index]
        guard let option = StudyAnswerMatcher.match(spoken, options: question.options) else {
            return "I didn't catch which option. Say the number or read the answer."
        }
        session.answers[question.id] = option.id
        session.index += 1
        if session.index >= session.questions.count {
            let result = grader.grade(session.questions, answers: session.answers)
            quizSession = nil
            return quizSummary(result)
        }
        quizSession = session
        return questionText(session.questions[session.index], number: session.index + 1, total: session.questions.count)
    }

    // MARK: - Flashcard review flow (spaced repetition)

    /// Start a flashcard review in due order; returns the first card's front, or nil if empty.
    func startReview(deckID: String) -> String? {
        guard let deck = store.deck(id: deckID), !deck.flashcards.isEmpty else { return nil }
        let now = clock()
        let records = deck.flashcards.map { store.reviewRecord(cardID: $0.id) ?? spaced.newRecord(cardID: $0.id, now: now) }
        let ordered = spaced.dueOrder(records, now: now).compactMap { rec in deck.flashcards.first { $0.id == rec.cardID } }
        reviewSession = ReviewSession(deckID: deckID, cards: ordered, index: 0, showingBack: false)
        return "Card 1 of \(ordered.count): \(ordered[0].front)"
    }

    func flip() -> String {
        guard var session = reviewSession, session.index < session.cards.count else { return "No card to flip." }
        session.showingBack = true
        reviewSession = session
        return session.cards[session.index].back
    }

    /// Grade the current card (correct → promote / space out; miss → resurface soon) and advance.
    func gradeCard(correct: Bool) -> String {
        guard var session = reviewSession, session.index < session.cards.count else { return "No card under review." }
        let card = session.cards[session.index]
        let now = clock()
        let record = store.reviewRecord(cardID: card.id) ?? spaced.newRecord(cardID: card.id, now: now)
        store.saveReviewRecord(spaced.update(record, correct: correct, now: now))
        session.index += 1
        session.showingBack = false
        if session.index >= session.cards.count {
            reviewSession = nil
            return "Review complete — \(session.cards.count) card\(session.cards.count == 1 ? "" : "s") reviewed."
        }
        reviewSession = session
        return "Card \(session.index + 1) of \(session.cards.count): \(session.cards[session.index].front)"
    }

    func stop() {
        quizSession = nil
        reviewSession = nil
    }

    // MARK: - Text helpers

    private func questionText(_ q: QuizQuestion, number: Int, total: Int) -> String {
        let opts = q.options.enumerated().map { "\($0.offset + 1)) \($0.element.text)" }.joined(separator: "  ")
        return "Question \(number) of \(total): \(q.prompt)\n\(opts)"
    }

    private func quizSummary(_ r: QuizResult) -> String {
        var out = "You scored \(r.correct)/\(r.total) (\(Int(r.percentage.rounded()))%)."
        if !r.missed.isEmpty {
            let missed = r.missed.compactMap { q in q.correctOption.map { "\(q.prompt) → \($0.text)" } }
            out += "\nReview: " + missed.joined(separator: "; ")
        }
        return out
    }
}
