import Foundation

/// The one place a relation is spelled.
///
/// Every edge that reaches [[BrainStore]] — from `BrainRelationExtractor`'s regexes, from
/// `BrainTool`'s `link` action, or from anything added later — is canonicalised and checked
/// against this closed allow-list. A relation outside it is *dropped, not stored*: the graph's
/// vocabulary cannot grow by accident out of free text, and that is the only thing that keeps
/// "functional relation" and "supersession" meaningful. Before this type the vocabulary was
/// implicit — the extractor's patterns, plus a switch inside the `link` action, plus whatever
/// string a caller happened to hand `addEdge`.
///
/// A silent rejection teaches nobody, so drops are counted per relation string in memory. The
/// *count* is what gets logged; the string itself never leaves the process, because it came from
/// free text and free text is the wearer's content.
enum RelationOntology {

    // MARK: - The vocabulary

    /// Every relation the graph will store. The first ten are what shipped before this list
    /// existed (nine from the extractor's patterns, plus `knows` from the `link` action, plus
    /// `mentioned_in` which ingestion synthesises); the rest are a small, deliberate extension
    /// for the shapes those ten kept almost expressing.
    static let allowed: Set<String> = [
        // In use before the ontology existed.
        "works_at", "leads", "founded", "invested_in", "lives_in",
        "married_to", "studied_at", "attended", "mentioned_in", "knows",
        // The deliberate extension.
        "reports_to", "owns", "member_of", "based_in", "parent_of", "sibling_of",
    ]

    /// Relations that hold exactly one value at a time, so a new destination retires the old one
    /// rather than sitting beside it. Kept deliberately small: supersession is destructive to a
    /// reader's sense of what is true, and a wrongly-functional relation ("founded", "attended")
    /// would hide facts that are all still true at once.
    static let functional: Set<String> = ["works_at", "lives_in", "married_to", "leads"]

    /// What kind of entity sits on the far end. Used when a caller states a relation without
    /// saying what it points at — `BrainTool.link` owned this switch inline before.
    private static let destinationKinds: [String: String] = [
        "works_at": "org", "leads": "org", "founded": "org", "invested_in": "org",
        "studied_at": "org", "owns": "org", "member_of": "org",
        "lives_in": "place", "based_in": "place",
        "married_to": "person", "knows": "person", "reports_to": "person",
        "parent_of": "person", "sibling_of": "person",
        "attended": "event",
        "mentioned_in": "source",
    ]

    /// How a retired edge reads. "Maria used to live in Wellington" — the point of keeping
    /// history is that it is legible as history, so every relation gets a real past form rather
    /// than "used to" glued onto a present tense.
    private static let pastPhrases: [String: String] = [
        "works_at": "used to work at",
        "leads": "used to lead",
        "founded": "founded",
        "invested_in": "invested in",
        "lives_in": "used to live in",
        "married_to": "was married to",
        "studied_at": "studied at",
        "attended": "attended",
        "mentioned_in": "was mentioned in",
        "knows": "used to know",
        "reports_to": "used to report to",
        "owns": "used to own",
        "member_of": "used to be a member of",
        "based_in": "used to be based in",
        "parent_of": "was a parent of",
        "sibling_of": "was a sibling of",
    ]

    // MARK: - Queries

    /// Lower-cased, trimmed, separators folded to underscores. The normalisation the `link`
    /// action already did inline, in one place so every entry point agrees.
    static func canonical(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    static func isAllowed(_ relation: String) -> Bool { allowed.contains(canonical(relation)) }

    static func isFunctional(_ relation: String) -> Bool { functional.contains(canonical(relation)) }

    /// The entity kind a relation points at; "org" for anything unlisted, which is what the
    /// `link` action's `default` branch did.
    static func destinationKind(for relation: String) -> String {
        destinationKinds[canonical(relation)] ?? "org"
    }

    /// Present tense, as edges have always rendered: underscores become spaces.
    static func phrase(for relation: String) -> String {
        canonical(relation).replacingOccurrences(of: "_", with: " ")
    }

    /// Past tense, for an edge that has been superseded.
    static func pastPhrase(for relation: String) -> String {
        pastPhrases[canonical(relation)] ?? "used to \(phrase(for: relation))"
    }

    /// The allow-list in a stable order, for a tool description or an error that has to say what
    /// it will accept.
    static var sortedRelations: [String] { allowed.sorted() }

    // MARK: - Drops

    /// Off-ontology relation strings seen this launch, counted by string. In memory only, and
    /// never logged: the string arrived in free text. Main-actor because every writer
    /// (`BrainStore.addEdge`, `BrainTool.link`) already runs there.
    @MainActor private(set) static var drops: [String: Int] = [:]

    /// Total drops this launch.
    @MainActor static var dropCount: Int { drops.values.reduce(0, +) }

    /// Record that a relation was refused. Extending the allow-list is then a one-line change
    /// made on evidence rather than on taste.
    @MainActor static func recordDrop(_ relation: String) {
        drops[canonical(relation), default: 0] += 1
        PrivacyLog.store(.brain, .dropped, count: dropCount, total: drops.count)
    }

    /// Test seam: the counter is process-wide, so a test that asserts on it starts from zero.
    @MainActor static func resetDrops() { drops.removeAll() }
}
