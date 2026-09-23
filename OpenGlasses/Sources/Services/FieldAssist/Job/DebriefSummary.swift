import Foundation

/// What a debrief amounts to: five short lists, each item citing the turn it came from
/// (Plan FO §6, P3b).
///
/// **Spoken items are the technician's report, not verified facts.** That is not a disclaimer
/// bolted on afterwards — it is the shape. Every item carries the ids of the debrief turns it was
/// drawn from, an item with no citation is rejected rather than trimmed, and an item that reads as
/// a completed check is flagged so the record cannot be mistaken for a task list. A debrief never
/// promotes "I should check the drier" into a check that happened.
struct DebriefSummary: Equatable {

    /// The five lists, in the order they are read back and printed. Raw values are the JSON keys
    /// the model is asked for, so the schema and the decoder cannot drift.
    enum Category: String, CaseIterable, Codable {
        case findings
        case followUps = "follow_ups"
        case forBase = "for_base"
        case partsOrMaterials = "parts_or_materials"
        case customerNotes = "customer_notes"

        /// The heading the read-back speaks and the work order prints.
        var heading: String {
            switch self {
            case .findings: return "What was found"
            case .followUps: return "Follow-ups"
            case .forBase: return "For base"
            case .partsOrMaterials: return "Parts and materials"
            case .customerNotes: return "Customer notes"
            }
        }
    }

    /// Why an item is marked. One case today, and a case rather than a Bool because the reason is
    /// what the record prints.
    enum Flag: String, Equatable, Codable {
        /// The item reads as work that was done. It stays in the record as the technician said it,
        /// with this beside it, because a debrief cannot establish that anything happened.
        case reportedNotVerified = "reported_not_verified"

        var note: String {
            switch self {
            case .reportedNotVerified: return "reported, not verified"
            }
        }
    }

    struct Item: Equatable {
        /// Short and verbatim-leaning: the technician's own words, not a paraphrase of them.
        let text: String
        /// The debrief turns this came from. Never empty — an item with no source is not an item.
        let sourceTurnIds: [String]
        let flag: Flag?

        init(text: String, sourceTurnIds: [String], flag: Flag? = nil) {
            self.text = text
            self.sourceTurnIds = sourceTurnIds
            self.flag = flag
        }

        /// "Drier looks wet — reported, not verified." — one line for the read-back and the page.
        var line: String {
            guard let flag else { return text }
            return "\(text) — \(flag.note)"
        }
    }

    /// The lists, keyed by category. A category with nothing in it is simply absent.
    let categories: [Category: [Item]]

    init(categories: [Category: [Item]]) {
        self.categories = categories.filter { !$0.value.isEmpty }
    }

    /// Every item, in reading order.
    var allItems: [(category: Category, item: Item)] {
        Category.allCases.flatMap { category in
            (categories[category] ?? []).map { (category: category, item: $0) }
        }
    }

    var isEmpty: Bool { categories.values.allSatisfy(\.isEmpty) }
    var itemCount: Int { categories.values.reduce(0) { $0 + $1.count } }

    func items(_ category: Category) -> [Item] { categories[category] ?? [] }

    /// A copy with one item replaced — what "change that one" does.
    func replacing(category: Category, at index: Int, with item: Item) -> DebriefSummary {
        var updated = categories
        guard var list = updated[category], list.indices.contains(index) else { return self }
        list[index] = item
        updated[category] = list
        return DebriefSummary(categories: updated)
    }

    /// A copy with one item taken out.
    func removing(category: Category, at index: Int) -> DebriefSummary {
        var updated = categories
        guard var list = updated[category], list.indices.contains(index) else { return self }
        list.remove(at: index)
        updated[category] = list
        return DebriefSummary(categories: updated)
    }

    // MARK: - How it reads

    /// The summary as the app reads it back and shows it: a heading per non-empty category, then
    /// its items. Nothing else — a read-back with an explanation in it is a read-back a technician
    /// stops listening to.
    var readBackLines: [String] {
        var lines: [String] = []
        for category in Category.allCases {
            let items = categories[category] ?? []
            guard !items.isEmpty else { continue }
            lines.append(category.heading + ":")
            lines.append(contentsOf: items.map { "  " + $0.line })
        }
        if lines.isEmpty { lines.append("Nothing came out of that one that I could write down.") }
        return lines
    }

    /// The whole read-back, spoken, with the question that ends it.
    var spokenReadBack: String {
        (readBackLines + [DebriefPrompt.decision.spoken]).joined(separator: "\n")
    }
}

// MARK: - The schema the model is asked for

extension DebriefSummary {

    /// How many items one category may carry, and how many the whole summary may. Bounded because
    /// a debrief is a short account of one visit: a model that returns thirty "findings" has
    /// started transcribing rather than summarising, and a read-back nobody listens to the end of
    /// is a read-back nobody confirmed.
    static let maximumItemsPerCategory = 6
    static let maximumItems = 20
    /// One item, in characters. Long enough for a sentence in the technician's own words.
    static let maximumItemCharacters = 240

    /// The JSON schema handed to the structured completion.
    static var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for category in Category.allCases {
            properties[category.rawValue] = [
                "type": "array",
                "maxItems": maximumItemsPerCategory,
                "description": itemDescription(category),
                "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string",
                                 "description": "The technician's own words, shortened but not "
                                    + "paraphrased. At most \(maximumItemCharacters) characters."],
                        "source_turn_ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "The ids of the debrief turns this came from. Required; "
                                + "an item with no source must be left out."
                        ]
                    ],
                    "required": ["text", "source_turn_ids"]
                ]
            ]
        }
        return ["type": "object", "properties": properties, "required": [] as [String]]
    }

    private static func itemDescription(_ category: Category) -> String {
        switch category {
        case .findings: return "What the technician says they found. Observations, not completed work."
        case .followUps: return "What they say still needs doing or checking."
        case .forBase: return "What the office or dispatcher needs to know."
        case .partsOrMaterials: return "Parts or materials they mention needing or having used."
        case .customerNotes: return "What the customer said or asked for."
        }
    }
}

// MARK: - Decoding and validation

/// Turns a model's JSON into a summary, or says exactly why it will not (Plan FO P3b).
///
/// Every rejection here is a rejection of something that would otherwise become part of a customer
/// record: an item nobody said, an item citing a turn that never happened, or a list long enough
/// that nobody would listen to the read-back. The decoder is pure and total — it never throws and
/// never partially applies.
enum DebriefSummaryDecoder {

    enum Failure: Equatable {
        case notAnObject
        /// Every category was missing or empty.
        case empty
        case itemWithoutCitation(category: String, text: String)
        case unknownTurnId(category: String, turnId: String)
        case tooManyItems(count: Int)

        /// What the app says out loud. Never the model's fault in the technician's ear — it is
        /// simply "that didn't come back right", with the two things they can do about it.
        var spoken: String {
            switch self {
            case .notAnObject, .empty:
                return "I couldn't get a summary out of that. Want me to try again, or keep what "
                    + "you said as it is?"
            case .itemWithoutCitation, .unknownTurnId, .tooManyItems:
                return "That summary didn't line up with what you said, so I've thrown it away. "
                    + "Want me to try again, or keep what you said as it is?"
            }
        }
    }

    /// Decode and validate. `turnIds` are the debrief's own turns — the only things an item may
    /// cite.
    static func decode(_ json: [String: Any], turnIds: [String]) -> Result<DebriefSummary, Failure> {
        let known = Set(turnIds)
        var categories: [DebriefSummary.Category: [DebriefSummary.Item]] = [:]
        var total = 0

        for category in DebriefSummary.Category.allCases {
            guard let raw = json[category.rawValue] as? [Any] else { continue }
            var items: [DebriefSummary.Item] = []
            for element in raw.prefix(DebriefSummary.maximumItemsPerCategory) {
                guard let dictionary = element as? [String: Any] else { continue }
                let text = (dictionary["text"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let cited = (dictionary["source_turn_ids"] as? [Any] ?? [])
                    .compactMap { $0 as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !cited.isEmpty else {
                    return .failure(.itemWithoutCitation(category: category.rawValue, text: text))
                }
                if let stranger = cited.first(where: { !known.contains($0) }) {
                    return .failure(.unknownTurnId(category: category.rawValue, turnId: stranger))
                }
                items.append(DebriefSummary.Item(text: String(text.prefix(DebriefSummary.maximumItemCharacters)),
                                                 sourceTurnIds: cited,
                                                 flag: flag(for: text, category: category)))
            }
            if !items.isEmpty {
                categories[category] = items
                total += items.count
            }
        }

        guard total > 0 else { return .failure(.empty) }
        guard total <= DebriefSummary.maximumItems else { return .failure(.tooManyItems(count: total)) }
        return .success(DebriefSummary(categories: categories))
    }

    /// Decode from raw bytes, for a provider that hands back a string.
    static func decode(jsonData: Data, turnIds: [String]) -> Result<DebriefSummary, Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dictionary = object as? [String: Any] else { return .failure(.notAnObject) }
        return decode(dictionary, turnIds: turnIds)
    }

    // MARK: - Promotions

    /// Words that turn an observation into a completed job. Present tense and past tense both:
    /// "replaced the drier" and "I'm replacing the drier" are equally not something this record
    /// may assert happened.
    static let completedWorkVerbs: Set<String> = [
        "replaced", "replacing", "fitted", "fitting", "cleaned", "cleaning", "repaired",
        "repairing", "tested", "testing", "checked", "checking", "measured", "measuring",
        "topped", "adjusted", "adjusting", "tightened", "reset", "recharged", "serviced",
        "installed", "installing", "rewired", "flushed", "calibrated", "verified", "confirmed"
    ]

    /// Whether an item reads as work that was carried out.
    ///
    /// The flag exists because a debrief item is a *report*: the technician may well have replaced
    /// the drier, and the tasks on the record say whether that was written down at the time. An
    /// item in `findings` that says so is kept word for word and marked, never rewritten and never
    /// turned into a task.
    static func readsAsCompletedWork(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // "should check", "needs checking", "want to test" are intentions, not completions.
        let intentions: Set<String> = ["should", "need", "needs", "needed", "want", "wants",
                                       "must", "could", "would", "going", "plan", "planning",
                                       "to", "still", "worth"]
        for (index, word) in words.enumerated() where completedWorkVerbs.contains(word) {
            let before = words[max(0, index - 3)..<index]
            if before.contains(where: { intentions.contains($0) }) { continue }
            return true
        }
        return false
    }

    private static func flag(for text: String,
                             category: DebriefSummary.Category) -> DebriefSummary.Flag? {
        // Only the two lists that could be read as a record of work. A follow-up or a customer
        // note saying "they'd already cleaned it" is not a claim about this visit.
        guard category == .findings || category == .partsOrMaterials else { return nil }
        return readsAsCompletedWork(text) ? .reportedNotVerified : nil
    }
}
