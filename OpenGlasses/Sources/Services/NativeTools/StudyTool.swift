import Foundation

/// `study` — Study Mode: turn a document into flashcards + a quiz and review hands-free. Delegates to
/// `StudyService.shared` (docs/plans/study-mode.md). Generation needs an LLM; review/quiz are stateful
/// across calls (like capture_flow / first_aid), driven one action at a time.
@MainActor
struct StudyTool: NativeTool {
    let name = "study"

    let description = """
    Study Mode — turn a document into flashcards + a quiz and review hands-free. Actions: scan (capture a \
    page through the camera via OCR — repeat for multiple pages, then make_deck), make_deck \
    (generate a deck from the scanned pages, a document name via 'deck', or raw 'text'), list (your decks), \
    quiz (start a quiz on a deck), answer (answer the current question via 'value' — a number or the option \
    text), review (start spaced-repetition flashcard review), flip (reveal the current card's back), grade \
    (mark the current card right/wrong via 'value'), stop. Use for "study this page", "make flashcards from X", "quiz me".
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["make_deck", "scan", "list", "quiz", "answer", "review", "flip", "grade", "stop"],
                    "description": "what to do"
                ],
                "deck": ["type": "string", "description": "deck id or document name (for make_deck/quiz/review)"],
                "text": ["type": "string", "description": "raw source text for make_deck (alternative to 'deck')"],
                "value": ["type": "string", "description": "the spoken answer (action=answer) or right/wrong (action=grade)"]
            ],
            "required": ["action"]
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let service = StudyService.shared
        let deckArg = (args["deck"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (args["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch (args["action"] as? String ?? "").lowercased() {
        case "make_deck":
            let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do {
                let deck: StudyDeck
                if !text.isEmpty {
                    deck = try await service.makeDeck(fromText: text, source: deckArg)
                } else if let deckArg, !deckArg.isEmpty {
                    deck = try await service.makeDeck(fromDocument: deckArg)
                } else if service.hasScannedPages {
                    deck = try await service.makeDeckFromScan()
                } else {
                    return "Tell me what to study — scan a page, give a document name ('deck'), or some 'text'."
                }
                return "Made deck “\(deck.summary.title)”: \(deck.flashcards.count) flashcards, \(deck.quiz.count) quiz questions. Say \"quiz me\" or \"review\"."
            } catch {
                return error.localizedDescription
            }

        case "scan":
            return await service.scanPage()

        case "list":
            let decks = service.store.decks
            guard !decks.isEmpty else { return "No study decks yet. Say \"make flashcards from <document>\"." }
            return "Your decks:\n" + decks.prefix(10).map { "• \($0.summary.title) — \($0.flashcards.count) cards, \($0.quiz.count) quiz" }.joined(separator: "\n")

        case "quiz":
            guard let id = resolveDeckID(deckArg, service: service) else { return noDeckMessage(service) }
            return service.startQuiz(deckID: id) ?? "That deck has no quiz questions. Try \"review\" for flashcards."

        case "answer":
            guard !value.isEmpty else { return "What's your answer? Say the number or the option." }
            return service.answerQuiz(value)

        case "review":
            guard let id = resolveDeckID(deckArg, service: service) else { return noDeckMessage(service) }
            return service.startReview(deckID: id) ?? "That deck has no flashcards."

        case "flip":
            return service.flip()

        case "grade":
            return service.gradeCard(correct: Self.isPositive(value))

        case "stop":
            service.stop()
            return "Study session stopped."

        default:
            return "Unknown action. Use make_deck, list, quiz, answer, review, flip, grade, or stop."
        }
    }

    /// Resolve a deck reference (id or fuzzy title) to a deck id, defaulting to the most recent deck.
    private func resolveDeckID(_ ref: String?, service: StudyService) -> String? {
        let decks = service.store.decks
        if let ref, !ref.isEmpty {
            if let exact = decks.first(where: { $0.id == ref }) { return exact.id }
            let q = ref.lowercased()
            if let byName = decks.first(where: { $0.summary.title.lowercased().contains(q) || ($0.source ?? "").lowercased().contains(q) }) {
                return byName.id
            }
        }
        return decks.first?.id   // latest
    }

    private func noDeckMessage(_ service: StudyService) -> String {
        service.store.decks.isEmpty
            ? "No study decks yet. Say \"make flashcards from <document>\" first."
            : "I couldn't find that deck. Say \"list decks\" to see them."
    }

    private static func isPositive(_ value: String) -> Bool {
        let v = value.lowercased()
        return ["yes", "y", "correct", "right", "got it", "true", "knew it", "pass"].contains { v.contains($0) }
    }
}
