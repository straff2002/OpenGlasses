import Foundation

/// Plan LV — a published vault's expected manuals against the documents the phone holds, pure.
///
/// Each expected manual (`CompanyVaultCatalog.ExpectedManual`) comes out **matched**, at a
/// **different revision** or **missing**, and every document no expectation took is an **extra**.
/// Matching goes by `revision` when both sides have one; otherwise by title and edition, compared
/// without regard to case or runs of whitespace. A document is taken by at most one expectation.
///
/// The rules, in order, for an expectation not matched by revision:
/// - no document with its title: missing;
/// - both sides have a revision and they differ: different revision;
/// - both sides have an edition and they differ: different revision;
/// - otherwise matched. An edition or revision known on one side only is no evidence of a
///   difference, so it never raises one (a company manual is laid in with its revision and no
///   edition; a partner may name a manual by title and edition only).
///
/// The phone never reports this anywhere: the portal works out its own checklist from what the
/// company uploaded, so a technician's own manuals stay off the service.
enum ExpectedManualMatch {

    /// One document the vault holds, as the match reads it.
    struct Held: Equatable, Sendable {
        let file: String
        let title: String
        let edition: String?
        let revision: String?
        let origin: VaultDocument.Origin?

        init(file: String, title: String, edition: String? = nil, revision: String? = nil, origin: VaultDocument.Origin? = nil) {
            self.file = file
            self.title = title
            self.edition = edition
            self.revision = revision
            self.origin = origin
        }

        init(_ document: VaultDocument) {
            self.init(file: document.file, title: document.title, edition: document.edition, revision: document.revision,
                      origin: document.origin)
        }
    }

    enum Status: Equatable, Sendable {
        /// The vault holds this manual: the document's file.
        case matched(file: String)
        /// The vault holds this manual at another revision or edition: the document's file.
        case differentRevision(file: String)
        case missing

        /// The document that answers for the expectation, if any.
        var file: String? {
            switch self {
            case .matched(let file), .differentRevision(let file): return file
            case .missing: return nil
            }
        }
    }

    struct Entry: Equatable, Sendable {
        let expected: CompanyVaultCatalog.ExpectedManual
        let status: Status
    }

    struct Summary: Equatable, Sendable {
        /// One per expected manual, in the row's order.
        let entries: [Entry]
        /// Documents the vault holds that no expectation took, in the vault's order.
        let extras: [Held]

        var expectedCount: Int { entries.count }
        var matchedCount: Int { entries.filter { if case .matched = $0.status { return true }; return false }.count }
        var differentRevisionCount: Int {
            entries.filter { if case .differentRevision = $0.status { return true }; return false }.count
        }
        var missingCount: Int { entries.filter { $0.status == .missing }.count }
        /// "9 of 12": the expected manuals held at all, whatever their revision.
        var heldCount: Int { expectedCount - missingCount }

        func entry(key: String) -> Entry? { entries.first { $0.expected.key == key } }
        func entry(documentFile file: String) -> Entry? { entries.first { $0.status.file == file } }
    }

    static func match(expects: [CompanyVaultCatalog.ExpectedManual], documents: [VaultDocument]) -> Summary {
        match(expects: expects, held: documents.map(Held.init))
    }

    static func match(expects: [CompanyVaultCatalog.ExpectedManual], held: [Held]) -> Summary {
        var taken = Set<Int>()
        var statuses = [Status?](repeating: nil, count: expects.count)

        // First, every expectation whose revision a document has exactly.
        for (index, expected) in expects.enumerated() {
            guard let revision = expected.revision,
                  let found = held.indices.first(where: { !taken.contains($0) && held[$0].revision == revision }) else { continue }
            taken.insert(found)
            statuses[index] = .matched(file: held[found].file)
        }

        // Then by title, preferring the document whose edition agrees, then one whose edition is
        // unknown, then any other with the title.
        for (index, expected) in expects.enumerated() where statuses[index] == nil {
            let title = normalized(expected.title)
            let candidates = held.indices.filter { !taken.contains($0) && normalized(held[$0].title) == title }
            guard !candidates.isEmpty else {
                statuses[index] = .missing
                continue
            }
            func rank(_ candidate: Int) -> Int {
                switch (expected.edition.map(normalized), held[candidate].edition.map(normalized)) {
                case let (wanted?, have?): return wanted == have ? 0 : 2
                default: return 1
                }
            }
            let chosen = candidates.min { rank($0) < rank($1) }!
            taken.insert(chosen)
            statuses[index] = differs(expected, held[chosen]) ? .differentRevision(file: held[chosen].file)
                                                              : .matched(file: held[chosen].file)
        }

        let entries = zip(expects, statuses).map { Entry(expected: $0, status: $1 ?? .missing) }
        let extras = held.indices.filter { !taken.contains($0) }.map { held[$0] }
        return Summary(entries: entries, extras: extras)
    }

    /// Whether a document with the expectation's title is evidently another revision of it.
    static func differs(_ expected: CompanyVaultCatalog.ExpectedManual, _ document: Held) -> Bool {
        if let wanted = expected.revision, let have = document.revision, wanted != have { return true }
        if let wanted = expected.edition.map(normalized), let have = document.edition.map(normalized), wanted != have {
            return true
        }
        return false
    }

    /// Lower case, whitespace runs folded to one space, trimmed.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
