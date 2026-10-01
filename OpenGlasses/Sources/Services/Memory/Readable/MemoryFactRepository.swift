import Foundation

/// Whether a source could be read just now.
enum MemorySourceStatus: Equatable, Sendable {
    case available
    /// Protected data is locked; the source's file exists but cannot be read until unlock.
    case locked
    /// The source could not be read, and why (content-free).
    case unavailable(String)

    var isAvailable: Bool { self == .available }
}

/// What one source returned: its facts, or a status saying why there are none to show.
struct MemorySourcePage: Equatable, Sendable {
    let sourceID: String
    let status: MemorySourceStatus
    let facts: [MemoryFact]

    static func available(_ sourceID: String, _ facts: [MemoryFact]) -> MemorySourcePage {
        MemorySourcePage(sourceID: sourceID, status: .available, facts: facts)
    }

    static func failed(_ sourceID: String, _ status: MemorySourceStatus) -> MemorySourcePage {
        MemorySourcePage(sourceID: sourceID, status: status, facts: [])
    }
}

/// An adapter over one authoritative store. Reads rebuild facts from the store every time; there
/// is no cache to go stale.
@MainActor
protocol MemoryFactSource {
    var sourceID: String { get }
    func page() -> MemorySourcePage
}

/// A source that contributed no facts, and why.
struct MemorySourceIssue: Equatable, Sendable {
    let sourceID: String
    let status: MemorySourceStatus
}

/// The merged read: facts in a stable order, plus a status row for every source that could not
/// be read. A partial set is never presented as everything.
struct MemoryFactListing: Equatable, Sendable {
    let facts: [MemoryFact]
    /// Sources that returned no facts because they could not be read.
    let unavailableSources: [MemorySourceIssue]

    var isComplete: Bool { unavailableSources.isEmpty }

    static let empty = MemoryFactListing(facts: [], unavailableSources: [])

    /// Counts per group, for the spoken summary and the screen's section headers.
    var countsByGroup: [MemoryFactGroup: Int] {
        Dictionary(grouping: facts, by: \.group).mapValues(\.count)
    }

    func fact(_ id: MemoryFactID) -> MemoryFact? { facts.first { $0.id == id } }
}

/// The façade over every fact source. Ephemeral: it merges what the sources return now and keeps
/// nothing (Plan DX invariant 1).
@MainActor
final class MemoryFactRepository {

    private let sources: [any MemoryFactSource]
    /// False while the phone is locked and protected files cannot be read. Every source then
    /// reports `.locked` without being asked, so nothing is read around the lock.
    private let protectedDataAvailable: @MainActor () -> Bool

    init(sources: [any MemoryFactSource],
         protectedDataAvailable: @escaping @MainActor () -> Bool = { true }) {
        self.sources = sources
        self.protectedDataAvailable = protectedDataAvailable
    }

    func load() -> MemoryFactListing {
        guard protectedDataAvailable() else {
            return Self.merge(sources.map { .failed($0.sourceID, .locked) })
        }
        return Self.merge(sources.map { $0.page() })
    }

    /// Pure merge. Newest first, ties broken by identity so the order never depends on which
    /// source answered first. A source that is not available contributes its status and **no
    /// rows**, even if it handed some back — a locked source shows a status, never stale rows.
    nonisolated static func merge(_ pages: [MemorySourcePage]) -> MemoryFactListing {
        var facts: [MemoryFact] = []
        var unavailable: [MemorySourceIssue] = []
        for page in pages {
            if page.status.isAvailable {
                facts.append(contentsOf: page.facts)
            } else {
                unavailable.append(MemorySourceIssue(sourceID: page.sourceID, status: page.status))
            }
        }
        return MemoryFactListing(facts: ordered(facts), unavailableSources: unavailable)
    }

    /// `(createdAt desc, id asc)`.
    nonisolated static func ordered(_ facts: [MemoryFact]) -> [MemoryFact] {
        facts.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id < b.id
        }
    }

    /// Facts whose text contains every word of `query`, case- and diacritic-insensitively.
    nonisolated static func search(_ facts: [MemoryFact], query: String) -> [MemoryFact] {
        let words = query.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return facts }
        return facts.filter { fact in
            let haystack = fact.text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                             locale: nil)
            return words.allSatisfy {
                haystack.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                             locale: nil))
            }
        }
    }
}
