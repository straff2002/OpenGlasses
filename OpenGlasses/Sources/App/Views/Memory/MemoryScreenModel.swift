import Foundation
import SwiftUI

/// The Memory screen's presentation model: what is listed, how it is grouped and labelled, and
/// the forget / correct flows. Kept free of views so the screen's behaviour is unit-tested.
@MainActor
final class MemoryScreenModel: ObservableObject {

    struct Section: Identifiable, Equatable {
        let group: MemoryFactGroup
        let facts: [MemoryFact]
        var id: MemoryFactGroup { group }
        /// Health starts folded away; the wearer opens it on purpose.
        var collapsedByDefault: Bool { group == .health }
    }

    @Published private(set) var listing: MemoryFactListing = .empty
    @Published var query: String = ""
    @Published var healthExpanded = false
    /// The forget the wearer has asked for and not yet confirmed.
    @Published var pendingForget: MemoryForgetPlan?
    /// Whether the confirmed forget also removes the matching lines of the assistant's notes.
    @Published var removeNoteLines = true
    /// The outcome of the last forget, shown until dismissed.
    @Published var lastForget: MemoryForgetResult?
    @Published private(set) var lastCorrectionFailed = false

    private let repository: MemoryFactRepository
    private let forgetter: MemoryFactForgetter?
    private let corrector: MemoryFactCorrector?

    init(repository: MemoryFactRepository, forgetter: MemoryFactForgetter?,
         corrector: MemoryFactCorrector?, initialQuery: String = "") {
        self.repository = repository
        self.forgetter = forgetter
        self.corrector = corrector
        self.query = initialQuery
    }

    func reload() {
        listing = repository.load()
    }

    // MARK: - What is shown

    var visibleFacts: [MemoryFact] {
        MemoryFactRepository.search(listing.facts, query: query)
    }

    var sections: [Section] {
        MemoryFactGrouper.grouped(visibleFacts).map { Section(group: $0.group, facts: $0.facts) }
    }

    /// Nothing saved anywhere and nothing unreadable: the teaching empty state.
    var showsEmptyState: Bool { listing.facts.isEmpty && listing.isComplete }

    /// One line per source that could not be read, so a partial list never reads as the whole.
    var statusMessages: [String] {
        listing.unavailableSources.map { Self.statusMessage(for: $0) }
    }

    func fact(_ id: MemoryFactID) -> MemoryFact? { listing.fact(id) }

    // MARK: - Labels

    static func title(for group: MemoryFactGroup) -> String {
        switch group {
        case .people: return String(localized: "People & family", comment: "Memory screen group heading.")
        case .places: return String(localized: "Places", comment: "Memory screen group heading.")
        case .preferences: return String(localized: "Preferences", comment: "Memory screen group heading.")
        case .unfinished: return String(localized: "Unfinished things", comment: "Memory screen group heading.")
        case .other: return String(localized: "Other", comment: "Memory screen group heading.")
        case .health: return String(localized: "Health", comment: "Memory screen group heading, collapsed by default.")
        }
    }

    static func originLabel(_ origin: MemoryOrigin) -> String {
        switch origin {
        case .toldMe: return String(localized: "You told me", comment: "Where a remembered fact came from.")
        case .inferred: return String(localized: "Inferred", comment: "Where a remembered fact came from: the assistant drew it from a conversation.")
        case .fromAddOn: return String(localized: "From an add-on", comment: "Where a remembered fact came from.")
        case .fromMeeting: return String(localized: "From a meeting", comment: "Where a remembered fact came from.")
        case .fromScan: return String(localized: "From something you scanned or read", comment: "Where a remembered fact came from.")
        case .imported: return String(localized: "Imported", comment: "Where a remembered fact came from.")
        case .legacyUnknown: return String(localized: "Saved before sources were recorded", comment: "Where a remembered fact came from: unknown, written by an older version.")
        }
    }

    static func storeLabel(_ store: MemoryFactStore) -> String {
        switch store {
        case .semantic: return String(localized: "Saved fact", comment: "Which kind of memory a fact is.")
        case .diary: return String(localized: "Assistant's observation", comment: "Which kind of memory a fact is.")
        case .brainEdge: return String(localized: "Connection", comment: "Which kind of memory a fact is: a link between people, places or organisations.")
        case .brainNeed: return String(localized: "Follow-up", comment: "Which kind of memory a fact is.")
        case .projectNote: return String(localized: "Project note", comment: "Which kind of memory a fact is.")
        case .agentNote: return String(localized: "Assistant's notes", comment: "Which kind of memory a fact is: a line of the assistant's own notes.")
        case .object: return String(localized: "Where you left something", comment: "Which kind of memory a fact is.")
        case .savedPlace: return String(localized: "Saved place", comment: "Which kind of memory a fact is.")
        }
    }

    static func statusMessage(for issue: MemorySourceIssue) -> String {
        let source: String
        switch issue.sourceID {
        case "semantic": source = String(localized: "Saved facts", comment: "Memory source name.")
        case "brain": source = String(localized: "People and connections", comment: "Memory source name.")
        case "agentNotes": source = String(localized: "The assistant's notes", comment: "Memory source name.")
        case "places": source = String(localized: "Places", comment: "Memory source name.")
        default: source = issue.sourceID
        }
        switch issue.status {
        case .locked:
            return String(localized: "\(source) are locked until you unlock your iPhone.",
                          comment: "Memory screen status row: a source cannot be read while the phone is locked.")
        case .unavailable, .available:
            return String(localized: "\(source) couldn't be read just now, so this list may be incomplete.",
                          comment: "Memory screen status row: a source could not be read.")
        }
    }

    /// VoiceOver reads the fact, then where it came from and when, then the actions.
    static func accessibilityLabel(for fact: MemoryFact) -> String {
        var parts = [fact.text, originLabel(fact.origin)]
        if fact.createdAt > .distantPast {
            parts.append(fact.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Forget

    func requestForget(_ fact: MemoryFact) {
        guard fact.capabilities.contains(.forget), let forgetter else { return }
        removeNoteLines = true
        pendingForget = forgetter.plan(for: fact)
    }

    func cancelForget() { pendingForget = nil }

    @discardableResult
    func confirmForget() async -> MemoryForgetResult? {
        guard let plan = pendingForget, let forgetter else { return nil }
        pendingForget = nil
        let result = await forgetter.forget(plan, removeNoteLines: removeNoteLines)
        lastForget = result
        reload()
        return result
    }

    /// Delete the conversation the forgotten fact came from — offered after a forget, never done
    /// as part of one (Plan GG decision 3).
    @discardableResult
    func deleteOriginatingConversation() async -> Bool {
        guard let thread = lastForget?.conversationThreadID, let forgetter else { return false }
        let deleted = await forgetter.deleteConversation(thread)
        lastForget = nil
        return deleted
    }

    // MARK: - Correct

    @discardableResult
    func correct(_ fact: MemoryFact, to value: String) -> MemoryCorrectionResult {
        guard let corrector else { return MemoryCorrectionResult(verified: false, newID: nil) }
        let result = corrector.correct(fact, to: value)
        lastCorrectionFailed = !result.verified
        reload()
        return result
    }
}
