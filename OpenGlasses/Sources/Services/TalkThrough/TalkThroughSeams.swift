import Foundation
import NaturalLanguage

// What a talk-through session talks to beyond live hints' own carriers (Plan JI §7a, P6b): the
// running procedure, and sentence similarity. Each is a protocol, so the session runs headless.

/// The running procedure, read and moved only as a spoken "next" moves it: `advanceProcedure`
/// and the photo-aware next the no-model voice uses. `FieldSessionService` in the app.
@MainActor
protocol TalkThroughProcedureHost: ProcedureAnswering {
    /// The procedure running now, nil when none is.
    var activeProcedure: Procedure? { get }
    /// The steps entered so far on this run, the current one last.
    var activeProcedureVisited: [String] { get }
}

extension FieldSessionService: TalkThroughProcedureHost {
    var activeProcedureVisited: [String] { activeProcedureRunner?.visited ?? [] }
}

/// How alike a sentence of narration and a step's own text are, 0…1, on the phone. Nil when there
/// is no embedder: the locator then decides on word overlap alone.
@MainActor
protocol TalkThroughSimilarity: AnyObject {
    func similarity(_ sentence: String, _ stepText: String) -> Double?
}

/// No similarity: word overlap alone.
@MainActor
final class NoTalkThroughSimilarity: TalkThroughSimilarity {
    init() {}
    func similarity(_ sentence: String, _ stepText: String) -> Double? { nil }
}

/// Sentence similarity from `Embedder` (NaturalLanguage's sentence embedding, on the phone; no
/// network, no model). Step vectors are kept for the session; a sentence is embedded once per
/// caption.
@MainActor
final class EmbedderTalkThroughSimilarity: TalkThroughSimilarity {
    private lazy var embedder = Embedder(language: .english)
    private var stepVectors: [String: [Float]] = [:]
    private var lastSentence: (text: String, vector: [Float]?)?

    init() {}

    func similarity(_ sentence: String, _ stepText: String) -> Double? {
        guard embedder.isAvailable else { return nil }
        let sentenceVector: [Float]?
        if let last = lastSentence, last.text == sentence {
            sentenceVector = last.vector
        } else {
            sentenceVector = embedder.embed(sentence)
            lastSentence = (sentence, sentenceVector)
        }
        guard let sentenceVector else { return nil }
        let stepVector: [Float]
        if let cached = stepVectors[stepText] {
            stepVector = cached
        } else {
            guard let vector = embedder.embed(stepText) else { return nil }
            stepVectors[stepText] = vector
            stepVector = vector
        }
        return Double(Embedder.cosineSimilarity(sentenceVector, stepVector))
    }

    /// The session ended: nothing of it is kept.
    func reset() {
        stepVectors = [:]
        lastSentence = nil
    }
}
