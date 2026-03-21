import Foundation

/// Social context: per-person memory that builds a dossier over time.
/// Extends face recognition by storing notes, topics, and context about each person.
/// "Remember that John works at Stripe and likes hiking"
/// "What do I know about John?"
struct SocialContextTool: NativeTool {
    let name = "social_context"
    let description = "Remember facts about people you meet. Actions: 'add' (store a fact about someone), 'recall' (what do I know about this person?), 'list' (all people with notes), 'forget' (clear facts about someone)."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "add, recall, list, or forget"],
                "person": ["type": "string", "description": "Person's name"],
                "fact": ["type": "string", "description": "A fact about this person (for add)"],
            ],
            "required": ["action"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "list").lowercased()
        let personName = (args["person"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "add", "remember", "note":
            guard let name = personName, !name.isEmpty else {
                return "Who is this about?"
            }
            guard let fact = args["fact"] as? String, !fact.isEmpty else {
                return "What should I remember about \(name)?"
            }
            SocialContextStore.shared.addFact(person: name, fact: fact)
            let count = SocialContextStore.shared.facts(for: name).count
            return "Noted about \(name): \(fact). I now have \(count) fact\(count == 1 ? "" : "s") about them."

        case "recall", "about", "who":
            guard let name = personName, !name.isEmpty else {
                return "Who do you want to know about?"
            }
            let facts = SocialContextStore.shared.facts(for: name)
            if facts.isEmpty {
                return "I don't have any notes about \(name). Tell me something about them and I'll remember."
            }
            let profile = SocialContextStore.shared.profile(for: name)
            return "About \(name): \(profile.facts.joined(separator: ". ")). First noted \(profile.timeKnownString) ago, \(profile.facts.count) facts."

        case "list", "people":
            let people = SocialContextStore.shared.allPeople()
            if people.isEmpty {
                return "I don't have notes about anyone yet. Tell me about someone you meet."
            }
            let list = people.map { person in
                let count = SocialContextStore.shared.facts(for: person).count
                return "\(person) (\(count) facts)"
            }.joined(separator: ", ")
            return "People I know about: \(list)"

        case "forget", "clear", "delete":
            guard let name = personName, !name.isEmpty else {
                return "Who should I forget about?"
            }
            SocialContextStore.shared.clearFacts(for: name)
            return "Cleared all notes about \(name)."

        default:
            return "Unknown action. Use: add, recall, list, or forget."
        }
    }
}

// MARK: - Storage

struct PersonProfile {
    let name: String
    let facts: [String]
    let firstSeen: Date

    var timeKnownString: String {
        let seconds = Int(Date().timeIntervalSince(firstSeen))
        if seconds < 3600 { return "\(max(1, seconds / 60)) minutes" }
        if seconds < 86400 { return "\(seconds / 3600) hours" }
        return "\(seconds / 86400) days"
    }
}

struct PersonFact: Codable {
    let fact: String
    let addedAt: Date
}

struct PersonEntry: Codable {
    let name: String
    var facts: [PersonFact]
    let firstSeen: Date
}

class SocialContextStore {
    static let shared = SocialContextStore()
    private let key = "socialContext"

    private func load() -> [PersonEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([PersonEntry].self, from: data) else { return [] }
        return entries
    }

    private func persist(_ entries: [PersonEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func addFact(person: String, fact: String) {
        var entries = load()
        let normalized = person.lowercased()
        if let idx = entries.firstIndex(where: { $0.name.lowercased() == normalized }) {
            entries[idx].facts.append(PersonFact(fact: fact, addedAt: Date()))
        } else {
            entries.append(PersonEntry(name: person, facts: [PersonFact(fact: fact, addedAt: Date())], firstSeen: Date()))
        }
        persist(entries)
    }

    func facts(for person: String) -> [String] {
        let normalized = person.lowercased()
        return load().first { $0.name.lowercased() == normalized }?.facts.map(\.fact) ?? []
    }

    func profile(for person: String) -> PersonProfile {
        let normalized = person.lowercased()
        guard let entry = load().first(where: { $0.name.lowercased() == normalized }) else {
            return PersonProfile(name: person, facts: [], firstSeen: Date())
        }
        return PersonProfile(name: entry.name, facts: entry.facts.map(\.fact), firstSeen: entry.firstSeen)
    }

    func allPeople() -> [String] {
        load().map(\.name).sorted()
    }

    func clearFacts(for person: String) {
        var entries = load()
        entries.removeAll { $0.name.lowercased() == person.lowercased() }
        persist(entries)
    }

    /// Generate prompt context for the AI to be aware of known people.
    func promptContext() -> String? {
        let entries = load()
        guard !entries.isEmpty else { return nil }
        var block = "\nPEOPLE YOU KNOW (from previous interactions):"
        for entry in entries.prefix(20) {
            let factList = entry.facts.suffix(3).map(\.fact).joined(separator: "; ")
            block += "\n- \(entry.name): \(factList)"
        }
        return block
    }
}
