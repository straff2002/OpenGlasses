import Foundation

/// Generates meeting/conversation summaries from ambient captions.
/// Detects when a meeting ends (prolonged silence after multi-speaker session)
/// and offers a summary with action items.
struct MeetingSummaryTool: NativeTool {
    let name = "meeting_summary"
    let description = "Generate a summary of a recent meeting or conversation from ambient captions. Extracts key points, decisions, and action items. Use when the user says 'summarize the meeting', 'what happened in that conversation?', or 'meeting notes'."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "mode": [
                "type": "string",
                "description": "Output mode: 'full' (summary + action items + decisions), 'brief' (short summary), 'action_items' (just action items)"
            ],
            "save": [
                "type": "boolean",
                "description": "Whether to save the summary as a note (default: true)"
            ]
        ],
        "required": []
    ]

    weak var captionService: AmbientCaptionService?
    /// Where the notes are written (Plan MX P4); nil uses the app's.
    private let notesServiceOverride: MeetingNotesService?

    init(captionService: AmbientCaptionService, notesService: MeetingNotesService? = nil) {
        self.captionService = captionService
        self.notesServiceOverride = notesService
    }

    func execute(args: [String: Any]) async throws -> String {
        await summarize(args: args).text
    }

    /// The summary as the tool says it, and — when there was a conversation to summarise — the
    /// same notes as a value (Plan KT P0), so a prepared card reads action items without parsing
    /// the prose.
    ///
    /// Plan MX P4: the model never runs inside this call. The turn answers with the phone's
    /// keyword facts and the transcript excerpt, as it always has, and the model's notes are
    /// written from the whole meeting once the turn is over (`MeetingNotesService.queue`), then
    /// complete the saved note, its action items and the latest summary. P6: when the model cannot
    /// run now they are owed, and written later.
    func summarize(args: [String: Any], now: Date = Date()) async -> MeetingSummaryOutput {
        guard let service = captionService else {
            return MeetingSummaryOutput(text: "Ambient caption service not available.", facts: nil)
        }

        // The whole session's transcript, oldest first (not the screen's capped history), with each
        // diarized line named as the registry names it now, and the model's window for the budget.
        let override = notesServiceOverride
        let snapshot = await MainActor.run { () -> (transcript: MeetingTranscriptBuffer, labeled: [String], budget: Int, notes: MeetingNotesService) in
            let transcript = service.meetingTranscript
            let registry = service.speakerRegistry
            let labeled = transcript.lines.map { line in
                line.speaker.map { "\(registry.displayLabel(for: $0)): \(line.text)" } ?? line.text
            }
            return (transcript, labeled, Self.excerptBudget(), override ?? MeetingNotesService.shared)
        }
        let lines = snapshot.transcript.lines

        guard !lines.isEmpty else {
            return MeetingSummaryOutput(
                text: "No conversation transcript available. Start ambient captions first, then have a conversation. I'll be able to summarize it afterward.",
                facts: nil)
        }

        let mode = (args["mode"] as? String)?.lowercased() ?? "full"
        let shouldSave = args["save"] as? Bool ?? true

        // The phone's keyword facts, over the whole meeting: the fallback, and what pins the
        // excerpt's lines.
        guard let phoneFacts = Self.facts(from: lines.map { (text: $0.text, timestamp: $0.timestamp) },
                                          savedAt: now) else {
            return MeetingSummaryOutput(text: "No conversation transcript available.", facts: nil)
        }

        let meetingId = UUID()
        let request = MeetingNotesRequest(
            id: meetingId,
            lines: zip(snapshot.labeled, lines).map { OwedMeetingNotes.Line(text: $0, at: $1.timestamp) },
            startedAt: phoneFacts.startedAt, endedAt: phoneFacts.endedAt,
            droppedLines: snapshot.transcript.dropped, saving: shouldSave)
        // Held in memory for the My Day cards' meeting follow-up (Plan KT P1); never written down.
        // Recorded before the write is queued, so the model's notes replace these when they come.
        LatestMeetingSummary.shared.record(phoneFacts)
        // Queued, never awaited: the stateless call swaps the conversation's history, so it runs
        // only once this turn is over.
        let outcome = snapshot.notes.queue(request)

        let pinned = MeetingTranscriptExcerpt.pinnedIndices(
            texts: lines.map(\.text), actionItems: phoneFacts.actionItems, decisions: phoneFacts.decisions)
        let content = MeetingSummaryContent(
            notes: nil, phoneFacts: phoneFacts,
            segments: lines.count,
            duration: Self.duration(of: lines.map(\.timestamp)),
            words: lines.reduce(0) { $0 + $1.text.split(separator: " ").count },
            droppedLines: snapshot.transcript.dropped,
            outcome: outcome, saved: shouldSave)
        let summary: String
        switch mode {
        case "brief":
            summary = content.brief()
        case "action_items":
            summary = content.actionItemsOnly()
        default: // "full"
            let excerpt = MeetingTranscriptExcerpt.make(
                lines: zip(snapshot.labeled, lines).map { .init(text: $0, timestamp: $1.timestamp) },
                pinned: pinned, budget: snapshot.budget)
            summary = content.full(excerpt: excerpt)
        }

        // Save as a note if requested, with the action items as a value so each can be added to
        // Reminders once (P5), and the meeting's id so owed notes complete this note (P6).
        if shouldSave {
            let dateStr = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short)
            let items = phoneFacts.actionItems.map { MeetingActionItem(task: $0) }
            var extra: [String: String] = [
                MeetingActionItemsRecord.meetingIdKey: meetingId.uuidString,
                MeetingActionItemsRecord.sourceKey: MeetingNotesSource.phone.rawValue,
            ]
            extra[MeetingActionItemsRecord.noteKey] = MeetingActionItemsRecord(items: items).encoded()
            saveNote(title: "Meeting Summary — \(dateStr)", content: summary,
                     date: ISO8601DateFormatter().string(from: now), extra: extra)
        }
        // The note is saved: the model's notes, written once this turn is over, have it to complete.
        if outcome == .queued { snapshot.notes.startQueuedWrites() }

        var guidance = "The LLM should present this summary conversationally to the user, highlighting the most important points."
        if content.showsCandidates, mode != "brief", mode != "action_items" {
            guidance += " Take what was agreed and who will do what from the transcript, not from the POSSIBLE lines alone."
        }
        return MeetingSummaryOutput(text: summary + "\n\n" + guidance, facts: phoneFacts)
    }

    /// The extraction as a value, over caption entries in time order. Nil for no entries.
    nonisolated static func facts(from entries: [(text: String, timestamp: Date)], savedAt: Date) -> MeetingSummaryFacts? {
        guard let first = entries.first, let last = entries.last else { return nil }
        let texts = entries.map(\.text)
        return MeetingSummaryFacts(
            actionItems: extractActionItems(from: texts),
            decisions: extractDecisions(from: texts),
            topics: extractTopics(from: texts),
            startedAt: min(first.timestamp, last.timestamp),
            endedAt: max(first.timestamp, last.timestamp),
            savedAt: savedAt,
            transcript: texts.joined(separator: "\n"))
    }

    // MARK: - Owed notes, written later (Plan MX P6)

    /// Owed notes were written: the saved note they belong to gets them — its content rebuilt
    /// from the owed transcript, its action items replaced (what was already added to Reminders
    /// stays added) — and the latest summary too, if it is still this meeting's. A note the
    /// wearer deleted meanwhile stays deleted.
    @MainActor
    static func completeSavedNote(_ record: OwedMeetingNotes, with notes: MeetingNotes, now: Date = Date()) {
        let texts = record.lines.map(\.text)
        guard let phoneFacts = facts(from: record.lines.map { (text: $0.text, timestamp: $0.at) }, savedAt: now) else {
            return
        }
        let content = MeetingSummaryContent(
            notes: notes, phoneFacts: phoneFacts, segments: record.lines.count,
            duration: duration(of: record.lines.map(\.at)),
            words: texts.reduce(0) { $0 + $1.split(separator: " ").count },
            droppedLines: record.droppedLines, outcome: .written(notes))
        let excerpt = MeetingTranscriptExcerpt.make(
            lines: record.lines.map { .init(text: $0.text, timestamp: $0.at) },
            pinned: MeetingTranscriptExcerpt.pinnedIndices(texts: texts, actionItems: phoneFacts.actionItems,
                                                           decisions: phoneFacts.decisions),
            budget: excerptBudget())
        let text = content.full(excerpt: excerpt)
        SavedNotesStore.update(whereKey: MeetingActionItemsRecord.meetingIdKey, is: record.id.uuidString) { note in
            note["content"] = text
            let previous = MeetingActionItemsRecord.decode(note[MeetingActionItemsRecord.noteKey])
                ?? MeetingActionItemsRecord(items: [])
            note[MeetingActionItemsRecord.noteKey] = previous.replacingItems(with: notes.actionItems).encoded()
            note[MeetingActionItemsRecord.sourceKey] = MeetingNotesSource.model.rawValue
        }
        if let latest = LatestMeetingSummary.shared.latest, latest.startedAt == record.startedAt,
           latest.endedAt == record.endedAt {
            LatestMeetingSummary.shared.record(latest.with(notes: notes))
        }
    }

    // MARK: - Local Extraction

    nonisolated static func extractActionItems(from texts: [String]) -> [String] {
        let actionPatterns = [
            "need to", "should", "will", "going to", "have to", "must",
            "let's", "let me", "i'll", "we'll", "please", "make sure",
            "don't forget", "remember to", "follow up", "send", "schedule",
            "set up", "prepare", "call", "email", "check", "review",
            "update", "fix", "create", "book", "arrange"
        ]

        var items: [String] = []
        for text in texts {
            let lower = text.lowercased()
            for pattern in actionPatterns {
                if lower.contains(pattern) {
                    // Extract the sentence containing the action pattern
                    let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
                    for sentence in sentences {
                        if sentence.lowercased().contains(pattern) {
                            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && trimmed.count > 10 && !items.contains(trimmed) {
                                items.append(trimmed)
                            }
                        }
                    }
                    break
                }
            }
        }
        return Array(items.prefix(10))
    }

    nonisolated static func extractDecisions(from texts: [String]) -> [String] {
        let decisionPatterns = [
            "decided", "agreed", "we're going with", "the plan is",
            "let's go with", "final answer", "confirmed", "approved",
            "we'll do", "settled on"
        ]

        var decisions: [String] = []
        for text in texts {
            let lower = text.lowercased()
            for pattern in decisionPatterns {
                if lower.contains(pattern) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !decisions.contains(trimmed) {
                        decisions.append(trimmed)
                    }
                    break
                }
            }
        }
        return Array(decisions.prefix(5))
    }

    nonisolated static func extractTopics(from texts: [String]) -> [String] {
        // Simple word frequency analysis for topic extraction
        let stopWords: Set<String> = ["the", "a", "an", "is", "it", "to", "and", "of", "in", "for",
                                       "that", "this", "with", "on", "at", "by", "from", "or", "but",
                                       "not", "be", "are", "was", "were", "been", "have", "has", "had",
                                       "do", "does", "did", "will", "would", "could", "should", "may",
                                       "can", "just", "so", "like", "yeah", "ok", "okay", "um", "uh",
                                       "i", "you", "we", "they", "he", "she", "my", "your", "our",
                                       "me", "him", "her", "them", "what", "how", "when", "where",
                                       "about", "going", "think", "know", "want", "need", "get", "got",
                                       "really", "very", "well", "also", "then", "than", "more", "some"]

        var wordCounts: [String: Int] = [:]
        for text in texts {
            let words = text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 && !stopWords.contains($0) }
            for word in words {
                wordCounts[word, default: 0] += 1
            }
        }

        return wordCounts
            .sorted { $0.value > $1.value }
            .prefix(10)
            .map { $0.key }
    }

    // MARK: - Helpers

    /// The excerpt's character budget, from the active model's context window where the app
    /// knows it (`ModelContextWindow`), else the conservative budget that fits a 4k model.
    @MainActor
    static func excerptBudget() -> Int {
        guard let config = Config.activeModel else {
            return MeetingTranscriptExcerpt.characterBudget(contextTokens: nil)
        }
        let catalogContext = config.llmProvider == .chatgpt
            ? ChatGPTContextCatalog.context(model: config.model, accountID: ChatGPTOAuthService.shared.accountID)
            : nil
        let window = ModelContextWindow.resolve(provider: config.llmProvider, model: config.model,
                                                baseURL: config.baseURL, chatGPTCatalogContext: catalogContext)
        return MeetingTranscriptExcerpt.characterBudget(contextTokens: window?.tokens)
    }

    /// From the first line to the last, in words.
    nonisolated static func duration(of timestamps: [Date]) -> String {
        guard let first = timestamps.min(), let last = timestamps.max() else {
            return "unknown"
        }
        let seconds = Int(last.timeIntervalSince(first))
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        let remainingMins = minutes % 60
        return "\(hours)h \(remainingMins)m"
    }

    private func saveNote(title: String, content: String, date: String, extra: [String: String]) {
        SavedNotesStore.append(title: title, content: content, date: date, extra: extra)

        // Feed the knowledge graph: typed edges from the summary, plus mentioned_in
        // edges linking known people to this meeting.
        BrainStore.shared.ingest(text: content, sourceRef: title, sourceKind: "meeting", origin: .fromMeeting)
    }
}

/// What `MeetingSummaryTool` said, as text for the model and as a value for code.
struct MeetingSummaryOutput {
    let text: String
    let facts: MeetingSummaryFacts?
}

/// One summarised conversation (Plan KT P0): the action items, decisions and topics the tool
/// extracted, the span of the captions it read and when the summary was made.
///
/// `transcript` is caption text — other people's words. It is held only so a draft built from the
/// action items can be checked for having copied anything else (`DraftValidator`); it is never
/// stored, logged or put in a prompt by anything in Plan KT.
///
/// Plan MX P4: when the model wrote the notes, `actionItems` are its items in readable form
/// (`MeetingActionItem.readable`: the task, with the owner and the due as said) and `decisions`
/// its decisions; `notes` carries them structured, with the title and the overview, and
/// `notesSource` says whose they are. Otherwise all three are the phone's keyword facts, as before.
struct MeetingSummaryFacts: Equatable, Sendable {
    let actionItems: [String]
    let decisions: [String]
    let topics: [String]
    let startedAt: Date
    let endedAt: Date
    let savedAt: Date
    let transcript: String
    /// The model's notes, when it wrote them.
    var notes: MeetingNotes? = nil
    var notesSource: MeetingNotesSource = .phone

    /// These facts with the model's notes in place of the keyword ones; unchanged for nil.
    func with(notes: MeetingNotes?) -> MeetingSummaryFacts {
        guard let notes else { return self }
        return MeetingSummaryFacts(actionItems: notes.actionItems.map(\.readable), decisions: notes.decisions,
                                   topics: topics, startedAt: startedAt, endedAt: endedAt, savedAt: savedAt,
                                   transcript: transcript, notes: notes, notesSource: .model)
    }
}

/// What a meeting summary says, in each of the tool's modes (Plan MX P4): the model's notes when
/// it wrote them, else the phone's keyword facts, with one neutral line saying which.
struct MeetingSummaryContent: Sendable {
    let notes: MeetingNotes?
    let phoneFacts: MeetingSummaryFacts
    let segments: Int
    let duration: String
    let words: Int
    let droppedLines: Int
    let outcome: MeetingNotesOutcome
    /// Whether the summary is saved as a note (what fuller notes would be added to).
    var saved: Bool = true

    init(notes: MeetingNotes?, phoneFacts: MeetingSummaryFacts, segments: Int, duration: String, words: Int,
         droppedLines: Int, outcome: MeetingNotesOutcome, saved: Bool = true) {
        self.notes = notes
        self.phoneFacts = phoneFacts
        self.segments = segments
        self.duration = duration
        self.words = words
        self.droppedLines = droppedLines
        self.outcome = outcome
        self.saved = saved
    }

    /// The phone's keyword lines are shown as candidates — what the phone picked out by key
    /// phrase, which may include things no one committed to — while the model's notes are still to
    /// come, so the turn's model reads the transcript rather than repeating them as action items.
    var showsCandidates: Bool { notes == nil && outcome.isPending }

    /// Which notes these are, said plainly.
    var sourceLine: String {
        if notes != nil { return "(These notes were written by the AI model from the meeting's transcript.)" }
        guard outcome.isPending else { return "(These notes were picked out on the phone from key phrases.)" }
        let when = outcome == .queued ? "after this reply" : "later"
        let whereTo = saved ? " and added to the saved note" : ""
        return "(These notes were picked out on the phone from key phrases. Fuller notes will be written \(when)\(whereTo).)"
    }

    /// Says what the POSSIBLE lines are, once, in the full summary.
    static let candidatesLine = "(Lines marked POSSIBLE were picked out on the phone by key phrase and may include things no one committed to; the transcript below is what was said.)"

    func brief() -> String {
        var parts = ["Conversation: \(segments) segments over \(duration) (~\(words) words)."]
        if let notes {
            if !notes.title.isEmpty { parts.append("\(notes.title).") }
            if !notes.overview.isEmpty { parts.append(notes.overview) }
        } else if !phoneFacts.topics.isEmpty {
            parts.append("Topics discussed: \(phoneFacts.topics.prefix(5).joined(separator: ", ")).")
        }
        return parts.joined(separator: " ") + "\n" + sourceLine
    }

    func actionItemsOnly() -> String {
        let items = notes?.actionItems.map(\.readable) ?? phoneFacts.actionItems
        let body: String
        if items.isEmpty {
            body = notes != nil ? "No one committed to an action item in the conversation."
                : "No clear action items detected in the conversation."
        } else {
            let header = showsCandidates
                ? "Possible action items, picked out on the phone by key phrase (some may be things no one committed to):"
                : "Action items from the conversation:"
            body = header + "\n" + items.map { "• \($0)" }.joined(separator: "\n")
        }
        return body + "\n" + sourceLine
    }

    func full(excerpt: MeetingTranscriptExcerpt) -> String {
        var parts: [String] = []
        parts.append(notes.map { $0.title.isEmpty ? "MEETING SUMMARY" : "MEETING SUMMARY: \($0.title)" } ?? "MEETING SUMMARY")
        parts.append("Duration: \(duration) | Segments: \(segments) | Words: ~\(words)")
        if droppedLines > 0 {
            parts.append("(This session ran past what is held in memory: its first \(MeetingTranscriptExcerpt.grouped(droppedLines)) lines are no longer available, so everything here starts after them.)")
        }
        parts.append(sourceLine)
        parts.append("")

        if let notes {
            if !notes.overview.isEmpty { parts.append("OVERVIEW: \(notes.overview)") }
            parts.append("")
            parts.append("DECISIONS:")
            if notes.decisions.isEmpty { parts.append("None were agreed.") }
            for d in notes.decisions.prefix(10) { parts.append("• \(d)") }
            parts.append("")
            parts.append("ACTION ITEMS:")
            if notes.actionItems.isEmpty { parts.append("No one committed to one.") }
            for a in notes.actionItems.prefix(10) { parts.append("• \(a.readable)") }
        } else {
            if !phoneFacts.topics.isEmpty {
                parts.append("KEY TOPICS: \(phoneFacts.topics.prefix(5).joined(separator: ", "))")
            }
            let possible = showsCandidates ? "POSSIBLE " : ""
            if !phoneFacts.decisions.isEmpty {
                parts.append("")
                parts.append("\(possible)DECISIONS:")
                for d in phoneFacts.decisions.prefix(5) { parts.append("• \(d)") }
            }
            if !phoneFacts.actionItems.isEmpty {
                parts.append("")
                parts.append("\(possible)ACTION ITEMS:")
                for a in phoneFacts.actionItems.prefix(5) { parts.append("• \(a)") }
            }
            if showsCandidates, !phoneFacts.decisions.isEmpty || !phoneFacts.actionItems.isEmpty {
                parts.append(Self.candidatesLine)
            }
        }

        parts.append("")
        parts.append(excerpt.header)
        parts.append(excerpt.text)
        return parts.joined(separator: "\n")
    }
}

/// The last meeting summary this run made, for the My Day cards' meeting follow-up (Plan KT P1).
/// In memory only, and only the latest: caption text is other people's words, so it is never
/// written to disk, logged or kept past the process.
final class LatestMeetingSummary: @unchecked Sendable {
    static let shared = LatestMeetingSummary()

    private let lock = NSLock()
    private var facts: MeetingSummaryFacts?

    func record(_ facts: MeetingSummaryFacts) {
        lock.lock()
        defer { lock.unlock() }
        self.facts = facts
    }

    var latest: MeetingSummaryFacts? {
        lock.lock()
        defer { lock.unlock() }
        return facts
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        facts = nil
    }
}
