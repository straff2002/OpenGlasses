import Foundation

/// A debrief, as it lands on the job's record (Plan FO §6, P3b).
///
/// Referred to in the plan as `WorkRecord.Debrief`, and available under that name — see the
/// `typealias` on `WorkRecord`. It is defined at the top level because `FieldSession` carries it
/// too, and a session that had to know about a work record to hold one would have the dependency
/// backwards.
///
/// **A debrief never reopens the job.** Nothing here touches time on the job, the tasks, the
/// equipment or the customer's sign-off: it is an appended account, dated, with the turns each
/// item came from and the model that summarised them. Several debriefs on one job are several
/// entries, each its own.
struct JobDebrief: Codable, Equatable, Identifiable {

    /// One summarised item, flattened so the encoding is stable and ordered. The pure
    /// `DebriefSummary` is the shape the app reasons in; this is the shape the record keeps.
    struct Entry: Codable, Equatable {
        /// `DebriefSummary.Category`'s raw value.
        let category: String
        let text: String
        let sourceTurnIds: [String]
        /// `DebriefSummary.Flag`'s raw value, when the item was marked.
        let flag: String?

        enum CodingKeys: String, CodingKey {
            case category
            case text
            case sourceTurnIds = "source_turn_ids"
            case flag
        }

        init(category: String, text: String, sourceTurnIds: [String], flag: String? = nil) {
            self.category = category
            self.text = text
            self.sourceTurnIds = sourceTurnIds
            self.flag = flag
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            category = try c.decode(String.self, forKey: .category)
            text = try c.decode(String.self, forKey: .text)
            sourceTurnIds = try c.decodeIfPresent([String].self, forKey: .sourceTurnIds) ?? []
            flag = try c.decodeIfPresent(String.self, forKey: .flag)
        }

        /// What the page and the work order print.
        var line: String {
            guard let flag, let known = DebriefSummary.Flag(rawValue: flag) else { return text }
            return "\(text) — \(known.note)"
        }
    }

    /// One turn of the conversation the summary was drawn from, kept so a citation resolves to
    /// something a reader can actually read.
    struct Turn: Codable, Equatable, Identifiable {
        let id: String
        let text: String
        /// Whole seconds, always — the same rule `AIProvenance` follows and for the same reason:
        /// this travels inside documents whose encoders use different date strategies, and a
        /// timestamp that survives one round trip but not another makes two copies of the same
        /// debrief unequal.
        let at: Date

        init(id: String, text: String, at: Date) {
            self.id = id
            self.text = text
            self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
        }

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case at
        }
    }

    let id: String
    /// When the technician said "save". Not when the debrief started — the save is the write.
    let recordedAt: Date
    let entries: [Entry]
    /// The debrief's own turns, in order.
    let turns: [Turn]
    /// True when the model could not be asked, or answered with something the decoder refused,
    /// and the technician chose to keep the account as it was said. The entries are then empty and
    /// the turns are the record; every surface says so out loud rather than printing a summary
    /// nobody made.
    let unsummarised: Bool
    /// The model that produced the summary, and a digest of the instructions it was given. Absent
    /// on an unsummarised debrief, which had no model in it at all.
    let provenance: AIProvenance?
    /// The conversation the debrief's turns landed in, so review can find them in place.
    let threadId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case recordedAt = "recorded_at"
        case entries
        case turns
        case unsummarised
        case provenance
        case threadId = "thread_id"
    }

    init(id: String = UUID().uuidString, recordedAt: Date = Date(), entries: [Entry],
         turns: [Turn], unsummarised: Bool = false, provenance: AIProvenance? = nil,
         threadId: String? = nil) {
        self.id = id
        // Truncated for the reason `Turn.at` is: an entry that survives one encoder's round trip
        // and not another's is an entry two readers can disagree about.
        self.recordedAt = Date(timeIntervalSince1970: recordedAt.timeIntervalSince1970.rounded(.down))
        self.entries = entries
        self.turns = turns
        self.unsummarised = unsummarised
        self.provenance = provenance
        self.threadId = threadId
    }

    /// Hand-written, for the same reason `WorkRecord`'s and `FieldSession`'s are: a record written
    /// before debriefs existed has none of these keys, and the synthesized decoder throws on a
    /// missing key for a non-optional collection.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        entries = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        unsummarised = try c.decodeIfPresent(Bool.self, forKey: .unsummarised) ?? false
        provenance = try c.decodeIfPresent(AIProvenance.self, forKey: .provenance)
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId)
    }

    // MARK: - Building one

    /// The debrief a saved summary produces.
    static func make(summary: DebriefSummary, turns: [Turn], provenance: AIProvenance?,
                     threadId: String?, id: String = UUID().uuidString,
                     recordedAt: Date = Date()) -> JobDebrief {
        JobDebrief(id: id, recordedAt: recordedAt,
                   entries: summary.allItems.map { pair in
                       Entry(category: pair.category.rawValue, text: pair.item.text,
                             sourceTurnIds: pair.item.sourceTurnIds, flag: pair.item.flag?.rawValue)
                   },
                   turns: turns, unsummarised: false, provenance: provenance, threadId: threadId)
    }

    /// The debrief a failed summary produces, when the technician chooses to keep what they said.
    static func unsummarised(turns: [Turn], threadId: String?, id: String = UUID().uuidString,
                             recordedAt: Date = Date()) -> JobDebrief {
        JobDebrief(id: id, recordedAt: recordedAt, entries: [], turns: turns,
                   unsummarised: true, provenance: nil, threadId: threadId)
    }

    // MARK: - How it reads

    /// The heading every surface uses, so the page, the work order and the read-back agree.
    static let blockTitle = "Debrief"

    /// What an unsummarised debrief is labelled with, wherever it appears. Never left to a reader
    /// to work out from an empty list.
    static let unsummarisedNote =
        "Not summarised — this is what the technician said, kept word for word."

    /// The sentence that says what a debrief is and is not, printed under the block.
    static let disclaimer =
        "Spoken after the visit and recorded as the technician's own account. Items here are "
        + "reports, not verified work: nothing in a debrief changes the tasks, the time on the job "
        + "or what the customer signed."

    /// "Debrief · 23 September 2026 at 16:40"
    func attributionLine(formatter: DateFormatter = CustomerSignOff.defaultFormatter) -> String {
        "\(Self.blockTitle) · \(formatter.string(from: recordedAt))"
    }

    /// The entries grouped under their headings, in the summary's own order — what the page shows
    /// and the work order prints.
    var summaryLines: [String] {
        guard !unsummarised else {
            return [Self.unsummarisedNote] + turns.map { "  \($0.text)" }
        }
        var lines: [String] = []
        for category in DebriefSummary.Category.allCases {
            let mine = entries.filter { $0.category == category.rawValue }
            guard !mine.isEmpty else { continue }
            lines.append(category.heading + ":")
            lines.append(contentsOf: mine.map { "  \($0.line)" })
        }
        if lines.isEmpty { lines.append("Nothing was recorded from this debrief.") }
        return lines
    }

    /// The text of the turns an entry cites, for a reader who wants to see what it came from.
    func sources(for entry: Entry) -> [Turn] {
        entry.sourceTurnIds.compactMap { id in turns.first { $0.id == id } }
    }
}

extension WorkRecord {
    /// The name Plan FO §6 uses for a debrief on the record.
    typealias Debrief = JobDebrief
}
