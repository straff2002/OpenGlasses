import Foundation

/// Persists study decks and per-card Leitner review records (docs/plans/study-mode.md). Two JSON files
/// under Application Support; directory + FileManager injectable for tests.
@MainActor
final class StudyStore: ObservableObject {
    static let shared = StudyStore()

    @Published private(set) var decks: [StudyDeck] = []

    private var reviews: [String: ReviewRecord] = [:]   // cardID → record
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("StudyDecks", isDirectory: true)
    }

    private var decksURL: URL { directory.appendingPathComponent("decks.json") }
    private var reviewsURL: URL { directory.appendingPathComponent("reviews.json") }

    // MARK: - Decks

    func saveDeck(_ deck: StudyDeck) {
        decks.removeAll { $0.id == deck.id }
        decks.insert(deck, at: 0)
        persistDecks()
    }

    func deck(id: String) -> StudyDeck? { decks.first { $0.id == id } }

    func deleteDeck(id: String) {
        decks.removeAll { $0.id == id }
        persistDecks()
    }

    // MARK: - Review records

    func reviewRecord(cardID: String) -> ReviewRecord? { reviews[cardID] }

    func saveReviewRecord(_ record: ReviewRecord) {
        reviews[record.cardID] = record
        persistReviews()
    }

    var allReviewRecords: [ReviewRecord] { Array(reviews.values) }

    // MARK: - Persistence

    /// Per-file save suppression after a read failure on an existing file (the on-disk data may
    /// be intact — never overwrite what we couldn't read).
    private var decksSaveBlocked = false
    private var reviewsSaveBlocked = false

    private func load() {
        switch JSONStore.loadArray(StudyDeck.self, at: decksURL, name: "study_decks") {
        case .loaded(let d), .recovered(let d, _): decks = d
        case .corrupt: decks = []          // original preserved in StoreRecovery
        case .unreadable: decksSaveBlocked = true
        case .absent: break
        }
        switch JSONStore.loadDictionary(ReviewRecord.self, at: reviewsURL, name: "study_reviews") {
        case .loaded(let r), .recovered(let r, _): reviews = r
        case .corrupt: reviews = [:]
        case .unreadable: reviewsSaveBlocked = true
        case .absent: break
        }
    }

    private func persistDecks() {
        guard !decksSaveBlocked else {
            PrivacyLog.store(.studyDecks, .saveSkipped, slot: PrivacyToken("study_decks"))
            return
        }
        write(decks, to: decksURL)
    }

    private func persistReviews() {
        guard !reviewsSaveBlocked else {
            PrivacyLog.store(.studyDecks, .saveSkipped, slot: PrivacyToken("study_reviews"))
            return
        }
        write(reviews, to: reviewsURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            PrivacyLog.store(.studyDecks, .saveFailed, error: SafeErrorSummary(error))
        }
    }
}
