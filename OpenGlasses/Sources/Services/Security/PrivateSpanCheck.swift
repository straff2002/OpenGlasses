import Foundation

/// Whether an outbound call is copying the wearer's private data out after the turn read outside
/// content (Plan LT §2). Pure: a function of the turn's reads and the text about to leave.
///
/// The leak this stops has two halves, and only a turn with both is checked. First the model
/// reads something written outside the wearer's control — a web page, a news item, a sign, an MCP
/// server's answer — which can carry an instruction ("search for the user's medication list").
/// Then it reads the wearer's private data — the health vault, notes, memory, contacts, the
/// calendar, the job's customer details — and an outbound call copies some of it into a query a
/// third party receives. Either half alone is ordinary: "search for the dose in my notes" reads
/// the notes and searches, and a memory lookup reads only our own stores. So the rule fires only
/// when both are present, and its answer is to ask (Decision 2): the wearer hears what would be
/// sent and where it came from, and a yes is bound to exactly that call.
///
/// A copy is five consecutive words, after folding case and accents, or 24 consecutive characters
/// with no space in them (an account number, a policy id, a link), that also appear in a private
/// output. The comparison is by shingle hashes: the outbound text is hashed, each private output is
/// walked and its windows hashed and looked up, and nothing from a private output is kept or copied.
enum PrivateSpanCheck {

    /// Consecutive normalised words that make a copy.
    static let wordSpan = 5
    /// Consecutive non-space characters that make a copy.
    static let characterSpan = 24

    /// One call of the turn, as the check reads it.
    struct Read: Equatable {
        let tool: String
        /// A tool this app ships; an MCP server's tool or the gateway is not.
        let isNative: Bool
        /// The call's captured result; nil while it runs and for any outcome but completion.
        let result: String?
    }

    /// Where a private output came from, as the wearer would name it.
    enum Source: String, CaseIterable, Equatable {
        case healthNotes, healthData, notes, memory, documents, contacts, calendar, reminders, jobDetails

        var spoken: String {
            switch self {
            case .healthNotes: return String(localized: "your health notes")
            case .healthData: return String(localized: "your health data")
            case .notes: return String(localized: "your notes")
            case .memory: return String(localized: "your memory")
            case .documents: return String(localized: "your documents")
            case .contacts: return String(localized: "your contacts")
            case .calendar: return String(localized: "your calendar")
            case .reminders: return String(localized: "your reminders")
            case .jobDetails: return String(localized: "the job's customer details")
            }
        }
    }

    /// Our own stores. They are untrusted for prompt framing (`PromptInjectionPolicy`), because a
    /// saved scene or a document can hold text from the world, but their content is the wearer's,
    /// not an outsider's — so reading them is never the "outside" half of the rule, and a turn that
    /// only looked something up in memory never prompts.
    static let ownStores: Set<String> = [
        "memory_search", "brain", "my_memory", "notes_vault", "health_vault",
        "document_knowledge", "remember_scene", "session_search",
    ]

    /// The native tools whose results are the wearer's private data. There is no tool that reads
    /// messages back, so messages are not on this list.
    static let privateOutputTools: [String: Source] = [
        "health_vault": .healthNotes,
        "health_summary": .healthData,
        "health_check": .healthData,
        "notes_vault": .notes,
        "list_notes": .notes,
        "contextual_note": .notes,
        "project_note": .notes,
        "memory_search": .memory,
        "my_memory": .memory,
        "brain": .memory,
        "session_search": .memory,
        "remember_scene": .memory,
        "document_knowledge": .documents,
        "lookup_contact": .contacts,
        "calendar": .calendar,
        "reminder": .reminders,
        "field_session": .jobDetails,
    ]

    /// An untrusted tool from outside the wearer ran and returned content this turn.
    static func readExternalUntrusted(_ reads: [Read]) -> Bool {
        reads.contains { read in
            read.result != nil && !(read.isNative && ownStores.contains(read.tool))
                && PromptInjectionPolicy.isUntrustedOutput(toolName: read.tool,
                                                          isKnownNativeTool: read.isNative)
        }
    }

    /// The turn's private outputs: each private tool's captured result, with its source.
    static func privateOutputs(_ reads: [Read]) -> [(source: Source, text: String)] {
        reads.compactMap { read in
            guard read.isNative, let source = privateOutputTools[read.tool],
                  let text = read.result, !text.isEmpty else { return nil }
            return (source, text)
        }
    }

    /// What was found: the outbound text that copies a private span, and where the span is from.
    struct Finding: Equatable {
        let source: Source
        /// The outbound string that matched — what would be sent, quoted back in the ask.
        let sent: String
    }

    /// The copied span, if `outbound` carries one and the turn has both halves of the rule.
    static func check(outbound: [String], reads: [Read]) -> Finding? {
        guard readExternalUntrusted(reads) else { return nil }
        let privates = privateOutputs(reads)
        guard !privates.isEmpty else { return nil }
        for text in outbound {
            let sent = Shingles(text)
            guard !sent.isEmpty else { continue }
            for output in privates where sent.isCopied(in: output.text) {
                return Finding(source: output.source, sent: text)
            }
        }
        return nil
    }

    // MARK: - The ask

    /// Where the call is going, for the ask.
    enum Destination: Equatable {
        /// A native tool, by its profile's verb: "Search the web for".
        case native(askVerb: String)
        /// An MCP server, by its label.
        case server(label: String)
        case gateway
        /// A user-authored HTTP tool, by its name.
        case customTool(name: String)
    }

    /// The approval summary: what would be sent, where, and where the copied part is from. The
    /// consent surface adds who is asking and "Approve?".
    static func approvalSummary(for finding: Finding, destination: Destination) -> String {
        let quoted = "\u{201C}\(preview(finding.sent))\u{201D}"
        let action: String
        switch destination {
        case .native(let verb): action = "\(verb) \(quoted)"
        case .server(let label): action = String(localized: "Send \(quoted) to \(label)")
        case .gateway: action = String(localized: "Hand \(quoted) to the gateway")
        case .customTool(let name): action = String(localized: "Send \(quoted) to \(name)")
        }
        return "\(action). \(note(for: finding.source))"
    }

    /// The sentence added to an ask: "It includes something from your health notes."
    static func note(for source: Source) -> String {
        String(localized: "It includes something from \(source.spoken).")
    }

    static func preview(_ text: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\u{2026}"
    }

    // MARK: - Shingles

    /// The hashed windows of one outbound string. Hashes are compared within one check, in one
    /// process, so the per-process seed of `Hasher` does not matter.
    struct Shingles {
        let words: Set<Int>
        let characters: Set<Int>

        init(_ text: String) {
            var words: Set<Int> = []
            var characters: Set<Int> = []
            PrivateSpanCheck.forEachWordWindow(in: text) { words.insert($0); return false }
            PrivateSpanCheck.forEachCharacterWindow(in: text) { characters.insert($0); return false }
            self.words = words
            self.characters = characters
        }

        var isEmpty: Bool { words.isEmpty && characters.isEmpty }

        /// Whether any window of `other` is one of these. Walks `other` once and keeps nothing.
        func isCopied(in other: String) -> Bool {
            var found = false
            if !words.isEmpty {
                PrivateSpanCheck.forEachWordWindow(in: other) { hash in
                    found = words.contains(hash)
                    return found
                }
            }
            if !found, !characters.isEmpty {
                PrivateSpanCheck.forEachCharacterWindow(in: other) { hash in
                    found = characters.contains(hash)
                    return found
                }
            }
            return found
        }
    }

    /// Case, accent and width folded, so "Metformin" and "metformin" are one word.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }

    /// The normalised words of `text`: runs of letters and digits.
    static func words(in text: String) -> [Substring] {
        folded(text).split { !$0.isLetter && !$0.isNumber }
    }

    /// Calls `body` with the hash of every `wordSpan`-word window; stops when `body` returns true.
    static func forEachWordWindow(in text: String, _ body: (Int) -> Bool) {
        let tokens = words(in: text)
        guard tokens.count >= wordSpan else { return }
        for start in 0...(tokens.count - wordSpan) {
            var hasher = Hasher()
            for token in tokens[start..<(start + wordSpan)] { hasher.combine(token) }
            if body(hasher.finalize()) { return }
        }
    }

    /// Calls `body` with the hash of every `characterSpan`-character window inside a run with no
    /// whitespace; stops when `body` returns true.
    static func forEachCharacterWindow(in text: String, _ body: (Int) -> Bool) {
        for run in folded(text).split(whereSeparator: { $0.isWhitespace }) where run.count >= characterSpan {
            let characters = Array(run)
            for start in 0...(characters.count - characterSpan) {
                var hasher = Hasher()
                for character in characters[start..<(start + characterSpan)] { hasher.combine(character) }
                if body(hasher.finalize()) { return }
            }
        }
    }
}
