import Foundation

// The adapters. Each reads its own store through that store's API, every time, and reports
// a status instead of rows when the store cannot be read. None of them writes.

/// Key/value facts and diary observations in `SemanticMemoryStore`, across every namespace —
/// shared facts and each persona's. Browsing them grants no new prompt access: what reaches a
/// prompt is still decided by the store's own namespace rules (Plan DX invariant 4).
@MainActor
struct SemanticFactSource: MemoryFactSource {
    let store: SemanticMemoryStore
    /// Diary observations are the assistant's own, so they show under Other with an "inferred"
    /// badge (Plan GG decision 4).
    var includeDiary = true
    var diaryLimit = 200

    var sourceID: String { "semantic" }

    func page() -> MemorySourcePage {
        guard store.isStorageAvailable else {
            return .failed(sourceID, .unavailable("memory storage could not be opened"))
        }
        var facts = store.allEntries().map(Self.fact(for:))
        if includeDiary {
            facts += store.readDiary(limit: diaryLimit).map { entry in
                MemoryFact(id: MemoryFactID(store: .diary, recordID: entry.id),
                           text: entry.text, kind: .diary, origin: .inferred,
                           createdAt: entry.createdAt)
            }
        }
        return .available(sourceID, facts)
    }

    nonisolated static func humanKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
    }

    nonisolated static func fact(for entry: SemanticMemoryStore.MemoryEntry) -> MemoryFact {
        MemoryFact(id: MemoryFactID(store: .semantic, recordID: entry.id),
                   text: "\(humanKey(entry.keyName)): \(entry.value)",
                   kind: .semantic(topic: entry.topic),
                   origin: entry.origin,
                   sourceRef: entry.sourceRef,
                   createdAt: entry.createdAt,
                   persona: entry.namespace == "global" ? nil : entry.namespace,
                   correctableValue: entry.value)
    }
}

/// Relations, open follow-ups and project notes in `BrainStore`. Retired (superseded) relations
/// are history, not facts, and are not listed; a forget removes them with the current claim.
/// `mentioned_in` links are bookkeeping between a person and a source, not something known about
/// anyone, so they are not listed either.
@MainActor
struct BrainFactSource: MemoryFactSource {
    let brain: BrainStore
    var limit = 500

    var sourceID: String { "brain" }

    func page() -> MemorySourcePage {
        guard brain.isStorageAvailable else {
            return .failed(sourceID, .unavailable("the knowledge graph could not be opened"))
        }
        var facts: [MemoryFact] = brain.allEdges(limit: limit).map(Self.fact(for:))
        facts += brain.needs(openOnly: true, limit: limit).map { need in
            MemoryFact(id: MemoryFactID(store: .brainNeed, recordID: need.id),
                       text: "Follow up with \(need.person): \(need.text)",
                       kind: .need, origin: .legacyUnknown, createdAt: need.createdAt,
                       correctableValue: need.text)
        }
        facts += brain.allProjectMemories(limit: limit).map { note in
            MemoryFact(id: MemoryFactID(store: .projectNote, recordID: note.id.uuidString),
                       text: note.text, kind: .projectNote, origin: .legacyUnknown,
                       sourceRef: note.projectTag, createdAt: note.createdAt)
        }
        return .available(sourceID, facts)
    }

    nonisolated static func fact(for edge: BrainStore.Edge) -> MemoryFact {
        MemoryFact(id: MemoryFactID(store: .brainEdge, recordID: edge.id),
                   text: "\(edge.srcName) \(RelationOntology.phrase(for: edge.relation)) \(edge.dstName)",
                   kind: .relation(relation: edge.relation, srcKind: edge.srcKind, dstKind: edge.dstKind),
                   origin: edge.origin,
                   sourceRef: edge.sourceRef,
                   createdAt: edge.validFrom ?? edge.createdAt,
                   correctableValue: edge.dstName)
    }
}

/// The agent's own `memory.md`: each bullet line is one fact. Nothing records where a line came
/// from, so every one is `legacyUnknown`.
@MainActor
struct AgentNotesFactSource: MemoryFactSource {
    let documents: AgentDocumentStore

    var sourceID: String { "agentNotes" }

    func page() -> MemorySourcePage {
        guard documents.isMemoryReadable else {
            return .failed(sourceID, .unavailable("the assistant's notes could not be read"))
        }
        return .available(sourceID, Self.facts(fromMemoryDocument: documents.content(for: .memory)))
    }

    /// Pure: one fact per distinct bullet line. Headings, comments and blank lines are structure.
    /// Identical lines are one fact, because removing "this line" removes every copy of it.
    nonisolated static func facts(fromMemoryDocument text: String) -> [MemoryFact] {
        var seen = Set<String>()
        var facts: [MemoryFact] = []
        for raw in text.components(separatedBy: "\n") {
            guard let parsed = AgentNoteLine(raw), seen.insert(raw).inserted else { continue }
            facts.append(MemoryFact(
                id: MemoryFactID(store: .agentNote, recordID: AgentNoteLine.recordID(for: raw)),
                text: parsed.text, kind: .agentNote, origin: .legacyUnknown,
                createdAt: parsed.learnedAt ?? .distantPast,
                correctableValue: parsed.text))
        }
        return facts
    }
}

/// One bullet of `memory.md`: `- fact text *(learned 2026-09-30T10:00:00Z)*`.
struct AgentNoteLine: Equatable {
    let text: String
    let learnedAt: Date?

    init?(_ raw: String) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
        line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        var learned: Date?
        if let open = line.range(of: "*(learned "), line.hasSuffix(")*") {
            let stamp = line[open.upperBound..<line.index(line.endIndex, offsetBy: -2)]
            learned = ISO8601DateFormatter().date(from: String(stamp))
            line = String(line[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !line.isEmpty else { return nil }
        text = line
        learnedAt = learned
    }

    /// A content-free, stable id for a raw line: the first 16 hex of its digest.
    static func recordID(for raw: String) -> String {
        String(MemoryTombstone.digest(raw).prefix(16))
    }

    /// The raw line rewritten with new text, keeping its learned stamp.
    static func rewrite(_ raw: String, text newText: String) -> String {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = raw.range(of: " *(learned "), raw.hasSuffix(")*") {
            return "- \(trimmed)\(raw[open.lowerBound...])"
        }
        return "- \(trimmed)"
    }
}

/// Remembered object locations and saved places — the wearer's "where things are".
@MainActor
struct PlacesFactSource: MemoryFactSource {
    let objects: ObjectMemoryStore
    let savedPlaces: SavedLocationStore

    var sourceID: String { "places" }

    func page() -> MemorySourcePage {
        var facts = objects.all().map { entry in
            MemoryFact(id: MemoryFactID(store: .object, recordID: entry.objectName),
                       text: "\(entry.objectName): \(entry.locationDescription)",
                       kind: .object, origin: .toldMe, createdAt: entry.savedAt,
                       correctableValue: entry.locationDescription)
        }
        facts += savedPlaces.all().map { place in
            MemoryFact(id: MemoryFactID(store: .savedPlace, recordID: place.recordID),
                       text: place.address.map { "\(place.label): \($0)" } ?? place.label,
                       kind: .savedPlace, origin: .toldMe, createdAt: place.timestamp,
                       correctableValue: place.label)
        }
        return .available(sourceID, facts)
    }
}
