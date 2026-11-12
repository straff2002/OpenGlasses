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
            // Plan LN: a note about someone else's health, money, beliefs or legal trouble — or an
            // ID number — is never kept, here or in the graph. The model hears the one sentence
            // to say instead of a claim that it was noted.
            let decision = SocialContextStore.shared.addFact(person: name, fact: fact)
            guard decision.isKept else {
                return decision.spokenNotice ?? MemoryRefusalNotice.sentence(for: decision.declinedCategory ?? .health)
            }
            // Feed the knowledge graph: the person becomes an entity (so meetings can
            // link to them) and "works at Stripe" becomes a typed edge.
            BrainStore.shared.upsertEntity(kind: "person", name: name)
            BrainStore.shared.ingest(text: fact, subject: name, origin: .toldMe)
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

/// The people tool's notes, one entry per person.
///
/// Lives in `social_context.json` beside `brain.sqlite`, with the same first-unlock protection and
/// backup exclusion (Plan LN decision 4). It used to be the preferences key `socialContext`, which
/// sits in the app's preferences file at the platform default protection and goes into every
/// backup; facts about other people do not belong there. The first open moves the key's contents
/// into the file and removes the key — once, idempotently, and never at the cost of the data: a
/// failed move leaves the key where it was and reads carry on from it.
///
/// Every note goes through `MemoryWriteGate` (destination `.people`, so always about someone else).
final class SocialContextStore {
    static let shared = SocialContextStore()

    /// The preferences key the notes lived under before the move.
    static let legacyDefaultsKey = "socialContext"
    static let fileName = "social_context.json"

    /// Injectable so tests can seed and clear a person without touching the wearer's own
    /// preference domain or documents.
    private let defaults: UserDefaults
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         fileManager: FileManager = .default) {
        let dir = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.defaults = defaults
        self.fileManager = fileManager
        self.fileURL = dir.appendingPathComponent(Self.fileName)
        migrateFromDefaultsIfNeeded()
        StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true,
                              to: fileURL, fileManager: fileManager)
    }

    // MARK: - Migration (Plan LN decision 4)

    /// Whether the notes still sit in the old preferences key.
    var hasLegacyEntries: Bool { defaults.object(forKey: Self.legacyDefaultsKey) != nil }

    /// Move the old key into the file: read it, write the file, then remove the key. A file that
    /// already exists is the result of an earlier move (or a later write), so the key is only
    /// removed. Anything that fails leaves the key in place for the next launch.
    private func migrateFromDefaultsIfNeeded() {
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey) else { return }
        if fileManager.fileExists(atPath: fileURL.path) {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            PrivacyLog.store(.socialContext, .legacyRetired)
            return
        }
        guard let entries = try? JSONDecoder().decode([PersonEntry].self, from: data) else {
            PrivacyLog.store(.socialContext, .loadFailed, detail: PrivacyToken("legacyUndecodable"))
            return
        }
        guard write(entries) else { return }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        PrivacyLog.store(.socialContext, .migrated, count: entries.count)
    }

    // MARK: - Storage

    private func load() -> [PersonEntry] {
        lock.lock(); defer { lock.unlock() }
        let data: Data?
        if fileManager.fileExists(atPath: fileURL.path) {
            data = try? Data(contentsOf: fileURL)
            if data == nil { PrivacyLog.store(.socialContext, .readFailed) }
        } else {
            // Not moved yet (the move failed this launch): the old key is still the truth.
            data = defaults.data(forKey: Self.legacyDefaultsKey)
        }
        guard let data, let entries = try? JSONDecoder().decode([PersonEntry].self, from: data) else { return [] }
        return entries
    }

    private func persist(_ entries: [PersonEntry]) {
        lock.lock(); defer { lock.unlock() }
        // A write that lands in the file retires the old key: the file now holds everything the
        // key did (it was read from the key when the file did not exist yet).
        if write(entries), defaults.object(forKey: Self.legacyDefaultsKey) != nil {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            PrivacyLog.store(.socialContext, .legacyRetired)
        }
    }

    /// Write the file atomically at first-unlock protection, excluded from backup.
    @discardableResult
    private func write(_ entries: [PersonEntry]) -> Bool {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            StoreProtection.apply(.completeUntilFirstUserAuthentication, backupExcluded: true,
                                  to: fileURL, fileManager: fileManager)
            return true
        } catch {
            PrivacyLog.store(.socialContext, .saveFailed, error: SafeErrorSummary(error))
            return false
        }
    }

    // MARK: - Notes

    /// Add a note about `person`, unless the write gate declines it. Returns the gate's decision;
    /// nothing is written unless it keeps the note.
    @discardableResult
    func addFact(person: String, fact: String, origin: MemoryOrigin = .toldMe) -> MemoryWritePolicy.Decision {
        let decision = MemoryWriteGate.decide(key: person, value: fact, origin: origin,
                                              destination: .people)
        if let category = decision.declinedCategory {
            PrivacyLog.store(.socialContext, .declined, detail: PrivacyToken(category.rawValue))
            return decision
        }
        var entries = load()
        let normalized = person.lowercased()
        if let idx = entries.firstIndex(where: { $0.name.lowercased() == normalized }) {
            entries[idx].facts.append(PersonFact(fact: fact, addedAt: Date()))
        } else {
            entries.append(PersonEntry(name: person, facts: [PersonFact(fact: fact, addedAt: Date())], firstSeen: Date()))
        }
        persist(entries)
        return decision
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

    /// The people the wearer has told the assistant about, for the prompt — inside the same
    /// untrusted-data envelope as saved memory (Plan LN §4): a note the wearer relayed can carry
    /// words someone else chose, and it is reference data, never an instruction.
    func promptContext() -> String? {
        let entries = load()
        guard !entries.isEmpty else { return nil }
        var block = "PEOPLE YOU KNOW (from previous interactions; bring one up only when the user does):"
        for entry in entries.prefix(20) {
            let factList = entry.facts.suffix(3).map(\.fact).joined(separator: "; ")
            block += "\n- \(entry.name): \(factList)"
        }
        return PromptInjectionPolicy.wrap(toolName: "people_notes", content: block)
    }
}
