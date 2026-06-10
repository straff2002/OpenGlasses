import Foundation

/// One query across everything the user's on-device brain knows — semantic memory, documents,
/// people, notes, meetings — plus the [[BrainStore]] knowledge graph (typed edges + encounter log).
/// Inspired by gbrain: returns cited findings and an explicit note on what the brain does NOT know,
/// so the LLM can synthesize an answer without overclaiming. Fully on-device; no gateway required.
struct BrainTool: NativeTool {
    let name = "brain"
    let description = """
    The user's unified on-device brain. 'query' searches ALL memory at once (facts, documents, \
    people, notes, meetings, knowledge graph) and returns cited findings plus what's missing — \
    prefer it over individual memory tools when unsure where something lives. 'person' builds a \
    dossier (facts, relationships, encounters) — use before/after meeting someone. 'link' records \
    a relationship ('Alice works at Acme'). 'encounters' lists recent face-recognition sightings. \
    'forget' erases an entity. 'status' reports brain size.
    """

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "query, person, link, encounters, forget, or status",
                           "enum": ["query", "person", "link", "encounters", "forget", "status"]],
                "question": ["type": "string", "description": "On 'query': what to look up."],
                "person": ["type": "string", "description": "On 'person'/'encounters'/'forget': the person or entity name."],
                "source": ["type": "string", "description": "On 'link': subject entity (e.g. 'Alice')."],
                "relation": ["type": "string", "description": "On 'link': works_at, lives_in, founded, leads, married_to, studied_at, invested_in, attended, or knows."],
                "target": ["type": "string", "description": "On 'link': object entity (e.g. 'Acme')."],
            ],
            "required": ["action"],
        ]
    }

    var memoryStore: SemanticMemoryStore?
    var documentStore: DocumentStore?

    private static let maxResultChars = 2200

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "query").lowercased()
        let brain = BrainStore.shared

        switch action {
        case "query", "search", "ask":
            guard let question = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !question.isEmpty else {
                return "What should I look up in the brain?"
            }
            return unifiedQuery(question, brain: brain)

        case "person", "dossier", "who":
            guard let person = (args["person"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !person.isEmpty else {
                return "Whose dossier do you want?"
            }
            return dossier(for: person, brain: brain)

        case "link", "relate", "connect":
            guard let src = (args["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty,
                  let relation = (args["relation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !relation.isEmpty,
                  let dst = (args["target"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !dst.isEmpty else {
                return "A link needs source, relation, and target (e.g. Alice / works_at / Acme)."
            }
            let normalizedRelation = relation.lowercased().replacingOccurrences(of: " ", with: "_")
            let dstKind: String
            switch normalizedRelation {
            case "lives_in": dstKind = "place"
            case "married_to", "knows": dstKind = "person"
            case "attended": dstKind = "event"
            default: dstKind = "org"
            }
            brain.addEdge(srcKind: "person", srcName: src, relation: normalizedRelation,
                          dstKind: dstKind, dstName: dst, sourceRef: "told directly")
            return "Linked: \(src) \(normalizedRelation.replacingOccurrences(of: "_", with: " ")) \(dst)."

        case "encounters", "sightings":
            let person = (args["person"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let encounters = brain.encounters(for: person?.isEmpty == false ? person : nil, limit: 8)
            if encounters.isEmpty {
                return person.map { "No logged encounters with \($0)." } ?? "No encounters logged yet. They're recorded automatically when face recognition spots a known person."
            }
            return "Recent encounters:\n" + encounters.map(describe).joined(separator: "\n")

        case "forget":
            guard let person = (args["person"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !person.isEmpty else {
                return "Who or what should I forget?"
            }
            brain.forget(entityName: person)
            return "Erased \(person) from the brain (entity, relationships, and encounters)."

        case "status", "stats":
            let stats = brain.stats
            let memoryCount = memoryStore != nil ? "available" : "disabled"
            let docCount = documentStore?.list().count ?? 0
            return "Brain: \(stats.entities) entities, \(stats.edges) relationships, \(stats.encounters) encounters. " +
                   "Semantic memory \(memoryCount); \(docCount) documents; \(SocialContextStore.shared.allPeople().count) people with notes."

        default:
            return "Unknown action. Use: query, person, link, encounters, forget, or status."
        }
    }

    // MARK: - Unified query

    private func unifiedQuery(_ question: String, brain: BrainStore) -> String {
        var sections: [String] = []
        var gaps: [String] = []

        // Knowledge graph: entities mentioned in the question, their edges and encounters.
        let mentioned = brain.entityNames(mentionedIn: question)
        var graphLines: [String] = []
        for entityName in mentioned.prefix(3) {
            graphLines += brain.neighbors(of: entityName, limit: 5).map { "- \($0.sentence) [graph]" }
            if let latest = brain.encounters(for: entityName, limit: 1).first {
                graphLines.append("- \(describe(latest)) [encounter log]")
            }
        }
        if graphLines.isEmpty { gaps.append("relationships") } else {
            sections.append("RELATIONSHIPS & ENCOUNTERS:\n" + graphLines.joined(separator: "\n"))
        }

        // Semantic memory (embedding search over remembered facts).
        let memoryHits = memoryStore?.semanticSearch(query: question, limit: 4) ?? []
        if memoryHits.isEmpty { gaps.append("remembered facts") } else {
            let lines = memoryHits.map { "- \($0.keyName): \($0.value) [memory, \(shortDate($0.createdAt))]" }
            sections.append("REMEMBERED FACTS:\n" + lines.joined(separator: "\n"))
        }

        // Documents (embedding search over ingested document chunks).
        let passages = documentStore?.query(question, limit: 3) ?? []
        if passages.isEmpty { gaps.append("documents") } else {
            let lines = passages.map { passage -> String in
                let locator = passage.page.map { ", p.\($0)" } ?? ""
                return "- \"\(snippet(passage.text))\" [doc: \(passage.documentName)\(locator)]"
            }
            sections.append("DOCUMENTS:\n" + lines.joined(separator: "\n"))
        }

        // People notes (keyword match over social-context facts).
        let queryWords = significantWords(in: question)
        var peopleLines: [String] = []
        for personName in SocialContextStore.shared.allPeople() {
            let facts = SocialContextStore.shared.facts(for: personName)
            let nameMatches = question.lowercased().contains(personName.lowercased())
            let matchingFacts = nameMatches ? facts : facts.filter { fact in
                let lowered = fact.lowercased()
                return queryWords.contains { lowered.contains($0) }
            }
            for fact in matchingFacts.prefix(nameMatches ? 4 : 2) {
                peopleLines.append("- \(personName): \(fact) [people notes]")
            }
        }
        if peopleLines.isEmpty { gaps.append("people notes") } else {
            sections.append("PEOPLE:\n" + peopleLines.prefix(6).joined(separator: "\n"))
        }

        // Meeting summaries (keyword match over saved notes).
        let meetingNotes = UserDefaults.standard.array(forKey: "saved_notes") as? [[String: String]] ?? []
        let meetingLines = meetingNotes.reversed().compactMap { note -> String? in
            guard let content = note["content"] else { return nil }
            let haystack = "\(note["title"] ?? "") \(content)".lowercased()
            guard queryWords.contains(where: { haystack.contains($0) }) else { return nil }
            return "- \(note["title"] ?? "Untitled"): \(snippet(content)) [meeting]"
        }.prefix(2)
        if meetingLines.isEmpty { gaps.append("meetings") } else {
            sections.append("MEETINGS:\n" + meetingLines.joined(separator: "\n"))
        }

        // Contextual notes (keyword + location).
        let noteHits = ContextualNoteStore.shared.search(question).prefix(2)
        if !noteHits.isEmpty {
            let lines = noteHits.map { "- \(snippet($0.content)) [note, \($0.locationName ?? "no location"), \($0.timeAgoString) ago]" }
            sections.append("CONTEXTUAL NOTES:\n" + lines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else {
            return "The brain has nothing on \"\(question)\" — no matching facts, documents, people, meetings, or relationships. " +
                   "Tell me things to remember, ingest documents, or add facts about people and I'll connect them."
        }

        var result = sections.joined(separator: "\n\n")
        if result.count > Self.maxResultChars {
            result = String(result.prefix(Self.maxResultChars)) + "…"
        }
        if !gaps.isEmpty {
            result += "\n\nNOT IN THE BRAIN: no matching \(gaps.joined(separator: ", ")). Answer only from the findings above; flag what's missing if relevant."
        }
        return result
    }

    // MARK: - Person dossier

    private func dossier(for person: String, brain: BrainStore) -> String {
        var sections: [String] = []

        let profile = SocialContextStore.shared.profile(for: person)
        if !profile.facts.isEmpty {
            sections.append("FACTS (known \(profile.timeKnownString)):\n" +
                            profile.facts.suffix(6).map { "- \($0)" }.joined(separator: "\n"))
        }

        let edges = brain.neighbors(of: person, limit: 8)
        if !edges.isEmpty {
            sections.append("RELATIONSHIPS:\n" + edges.map { "- \($0.sentence)" }.joined(separator: "\n"))
        }

        let encounters = brain.encounters(for: person, limit: 3)
        if !encounters.isEmpty {
            sections.append("RECENT ENCOUNTERS:\n" + encounters.map(describe).joined(separator: "\n"))
        }

        let memoryHits = memoryStore?.semanticSearch(query: person, limit: 3) ?? []
        if !memoryHits.isEmpty {
            sections.append("FROM MEMORY:\n" + memoryHits.map { "- \($0.keyName): \($0.value)" }.joined(separator: "\n"))
        }

        guard !sections.isEmpty else {
            return "The brain has nothing on \(person) yet. Add facts ('remember that \(person)…'), " +
                   "teach face recognition, or link relationships, and the dossier builds itself."
        }
        return "DOSSIER — \(person):\n\n" + sections.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func describe(_ encounter: BrainStore.Encounter) -> String {
        let formatter = RelativeDateTimeFormatter()
        let when = formatter.localizedString(for: encounter.occurredAt, relativeTo: Date())
        var line = "- Saw \(encounter.person) \(when)"
        if let location = encounter.locationName { line += " at \(location)" }
        if let context = encounter.context { line += " (\(context))" }
        return line
    }

    private func significantWords(in text: String) -> [String] {
        let stopwords: Set<String> = ["what", "when", "where", "who", "how", "did", "does", "the",
                                      "about", "know", "tell", "with", "have", "this", "that", "for",
                                      "and", "was", "are", "you", "they", "from", "last", "recent"]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }
    }

    private func snippet(_ text: String, max: Int = 160) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max)) + "…"
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
