import Foundation

/// What the structured call came back with, before anything is kept: the fields as the model wrote
/// them. Read from the JSON object the call returns; nothing is trusted yet.
struct ConversationDigestDraft: Equatable, Sendable {
    struct RawPoint: Equatable, Sendable {
        let kind: String
        let text: String
    }

    let headline: String?
    let points: [RawPoint]?

    init(headline: String?, points: [RawPoint]?) {
        self.headline = headline
        self.points = points
    }

    /// The draft in a returned JSON object. A field of the wrong type reads as missing, which the
    /// acceptance policy then refuses by name.
    init(object: [String: Any]) {
        headline = object["headline"] as? String
        if let raw = object["points"] as? [Any] {
            points = raw.map { item in
                let point = item as? [String: Any]
                return RawPoint(kind: point?["kind"] as? String ?? "", text: point?["text"] as? String ?? "")
            }
        } else {
            points = nil
        }
    }
}

/// What a call came back with: the draft, and whether the model finished rather than stopping at
/// its limit.
struct ConversationDigestCompletion: Equatable, Sendable {
    let draft: ConversationDigestDraft
    let finishedNormally: Bool
}

/// Why a call produced no note. A closed set, safe to log.
enum ConversationDigestError: String, Error, Equatable, Sendable {
    /// No model, or the call returned nothing it could read.
    case unavailable
}

/// Plan LQ §4 — what is kept of the model's answer. Pure.
///
/// 1. **Shape.** Finished normally, a headline present and in length, at most five points, every
///    kind one this build knows. Anything else is no note.
/// 2. **No copying.** A point that shares a run of `copyRunWords` words with any one message is
///    dropped; a headline that does is no note. A note is never a way to carry a manual's or an
///    email's text out of the conversation.
/// 3. **LN's gate.** The headline and each point go through `MemoryWriteGate` as an inferred write:
///    a sensitive point about someone else is dropped, so is a sensitive inferred point about the
///    wearer, and so is an instruction-shaped one. A point is dropped whole, never rewritten vaguer.
///    A dropped headline means no note, and the word-prefix summary stays.
enum ConversationDigestAcceptance {

    static let copyRunWords = 12

    enum Rejection: String, Equatable, Sendable {
        case cutOff
        case missingHeadline
        case headlineTooLong
        case tooManyPoints
        case unknownKind
        case headlineCopied
        case headlineDeclined
    }

    /// Why one point was left out. Counted in the log by this name only.
    enum DropReason: Equatable, Sendable {
        case empty
        case tooLong
        case copied
        case declined(MemorySensitivity.Category)

        var token: String {
            switch self {
            case .empty: return "empty"
            case .tooLong: return "tooLong"
            case .copied: return "copied"
            case .declined(let category): return category.rawValue
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case accepted(headline: String, points: [ConversationDigest.Point], dropped: [DropReason])
        case rejected(Rejection)
    }

    /// - Parameter messages: the text of every conversational message in the thread, so a quote
    ///   from a reply that was never sent is caught as surely as one from a reply that was.
    static func evaluate(_ completion: ConversationDigestCompletion, messages: [String]) -> Outcome {
        guard completion.finishedNormally else { return .rejected(.cutOff) }
        let draft = completion.draft
        let headline = (draft.headline ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !headline.isEmpty, !headline.contains("\n") else { return .rejected(.missingHeadline) }
        guard headline.count <= ConversationDigest.maximumHeadlineCharacters else {
            return .rejected(.headlineTooLong)
        }
        let raw = draft.points ?? []
        guard raw.count <= ConversationDigest.maximumPoints else { return .rejected(.tooManyPoints) }
        var kinds: [ConversationDigest.Kind] = []
        for point in raw {
            guard let kind = ConversationDigest.Kind(rawValue: point.kind) else { return .rejected(.unknownKind) }
            kinds.append(kind)
        }

        let runs = shingles(in: messages)
        if copies(headline, runs) { return .rejected(.headlineCopied) }
        if gate(headline) != nil { return .rejected(.headlineDeclined) }

        var kept: [ConversationDigest.Point] = []
        var dropped: [DropReason] = []
        for (point, kind) in zip(raw, kinds) {
            let text = point.text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if text.isEmpty { dropped.append(.empty); continue }
            if text.count > ConversationDigest.maximumPointCharacters { dropped.append(.tooLong); continue }
            if copies(text, runs) { dropped.append(.copied); continue }
            if let category = gate(text) { dropped.append(.declined(category)); continue }
            kept.append(ConversationDigest.Point(kind: kind, text: text))
        }
        return .accepted(headline: headline, points: kept, dropped: dropped)
    }

    /// The category LN's gate declines `text` for as an inferred memory, or nil when it keeps it.
    static func gate(_ text: String) -> MemorySensitivity.Category? {
        let decision = MemoryWriteGate.decide(key: "", value: text, origin: .inferred, destination: .memory)
        return decision.isKept ? nil : decision.declinedCategory
    }

    // MARK: - Copying

    /// Whether `text` shares a run of `copyRunWords` words with one of the messages.
    static func copies(_ text: String, _ runs: Set<String>) -> Bool {
        guard !runs.isEmpty else { return false }
        return !shingles(of: words(text)).isDisjoint(with: runs)
    }

    /// Every run of `copyRunWords` words in each message. A run never spans two messages.
    static func shingles(in messages: [String]) -> Set<String> {
        messages.reduce(into: Set<String>()) { $0.formUnion(shingles(of: words($1))) }
    }

    private static func shingles(of words: [String]) -> Set<String> {
        guard words.count >= copyRunWords else { return [] }
        var runs = Set<String>()
        for start in 0...(words.count - copyRunWords) {
            runs.insert(words[start..<(start + copyRunWords)].joined(separator: " "))
        }
        return runs
    }

    /// Lower-cased, diacritics folded, split on anything that is not a letter or a digit.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
