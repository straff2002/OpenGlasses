import Foundation

/// One finished turn as the lens showed it (Plan MG §3): the question line, the answer, its
/// follow-ups and whether it staged a manual page. Pure data.
struct LensConversationTurn: Equatable {
    /// The answer card's serial for the turn: the same while one answer grows.
    let id: Int
    /// The question line as the card drew it ("You: …"); nil for a turn the app started.
    let question: String?
    let answer: String
    let followUps: [String]
    let stagedPage: Bool
    let madeAt: Date
}

/// What the lens remembers of this conversation (Plan MG §3): a ring of the last
/// `capacity` finished turns, oldest first. Pure and in memory only.
///
/// - It takes in only what the answer card already showed (Direct-mode turns, live turns through
///   `LiveAnswerCardFeed`), never anything else, so it adds no new place where conversation text
///   lives.
/// - It is **never written to disk** and never goes to a model, to memory, to BrainStore or into
///   the support report: the report gets `count` only.
/// - The card clears it when the conversation ends, when a private conversation ends, when the HUD
///   is turned off, and when the glasses stay disconnected for longer than the card's lifetime.
struct LensConversationLog: Equatable {
    /// Decision 2: this conversation's last 10 answers.
    static let capacity = 10

    /// Oldest first.
    private(set) var turns: [LensConversationTurn] = []

    var isEmpty: Bool { turns.isEmpty }
    var count: Int { turns.count }
    var latest: LensConversationTurn? { turns.last }
    var newestFirst: [LensConversationTurn] { turns.reversed() }

    func turn(id: Int) -> LensConversationTurn? { turns.first { $0.id == id } }

    /// The turns older than `id`, newest first; every turn when `id` is nil, and none when the
    /// log doesn't hold it (a turn too old to remember has nothing older that is).
    func earlier(than id: Int?) -> [LensConversationTurn] {
        guard let id else { return newestFirst }
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(turns[..<index].reversed())
    }

    /// The turn just before `id` — what "earlier" opens.
    func turn(before id: Int) -> LensConversationTurn? { earlier(than: id).first }

    /// Take in a finished turn, or the same turn again with more of it (its follow-ups, a page it
    /// staged): a turn already held keeps its place. Past `capacity`, the oldest goes.
    mutating func record(_ turn: LensConversationTurn) {
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            turns[index] = turn
            return
        }
        turns.append(turn)
        if turns.count > Self.capacity { turns.removeFirst(turns.count - Self.capacity) }
    }

    mutating func clear() {
        turns = []
    }
}
