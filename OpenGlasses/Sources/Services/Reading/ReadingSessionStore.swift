import Foundation

/// Persists reading sessions and their page captures (docs/plans/BT-reading-companion.md P1).
/// One JSON file under Application Support; directory + FileManager injectable for tests.
///
/// This is the reading companion's grounding corpus and the *only* thing the assistant is allowed
/// to answer from — see `ReadingContextBuilder`. Nothing about a book beyond what the reader has
/// looked at ever enters it, which is what makes the spoiler rule structural rather than a promise
/// in a prompt.
///
/// The store is deliberately dumb about lifecycle: it never decides which session is "current"
/// (that's the P2 service) and it derives every statistic on demand rather than storing it, so
/// stats can't drift away from the captures they describe.
@MainActor
final class ReadingSessionStore: ObservableObject {
    static let shared = ReadingSessionStore()

    /// Newest-first, matching the house convention for list-backing stores.
    @Published private(set) var sessions: [ReadingSession] = []

    /// Reference copies by bookID (P4) — pointers into `DocumentStore`, own file so the P1
    /// sessions schema is untouched and old data decodes unchanged.
    @Published private(set) var references: [String: BookReference] = [:]

    private let directory: URL
    private let fileManager: FileManager
    private let duplicateHashDistance: Int

    /// Captures rejected as duplicates. In-memory diagnostic (review finding: a hash-collision
    /// false duplicate silently drops a page the reader did read — this is the counter that makes
    /// that visible on the P3 device pass, alongside `unreadableCaptures` on the service).
    private(set) var dedupDropCount = 0

    /// Below this length, matching text means "OCR found nothing much" rather than "same page", so
    /// text-equality dedup is only trusted on a real paragraph's worth of characters.
    private static let minimumTextMatchLength = 40

    /// Hash-only dedup applies only to the last N pages. A re-look is at the current spread or a
    /// page just read; letting a bare hash match reach the whole book lets a 9×8 dhash collision
    /// (two dense prose pages share margins and column structure) silently drop a genuinely new
    /// page. Older pages can still dedup, but only with the text corroborating.
    private static let hashDedupWindow = 8

    /// - Parameters:
    ///   - duplicateHashDistance: Hamming distance at/below which a capture is the same page as one
    ///     already filed. Tight by default (2 of 64): a missed duplicate merely repeats a page in
    ///     the corpus, whereas a false duplicate silently drops a page the reader did read, so the
    ///     error that costs data is the one to avoid.
    init(directory: URL? = nil, fileManager: FileManager = .default, duplicateHashDistance: Int = 2) {
        self.fileManager = fileManager
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.duplicateHashDistance = max(0, duplicateHashDistance)
        load()
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ReadingSessions", isDirectory: true)
    }

    private var sessionsURL: URL { directory.appendingPathComponent("sessions.json") }
    private var referencesURL: URL { directory.appendingPathComponent("references.json") }

    // MARK: - Reference copies (P4)

    func reference(forBook bookID: String) -> BookReference? { references[bookID] }

    func attachReference(_ reference: BookReference) {
        references[reference.bookID] = reference
        persistReferences()
    }

    func detachReference(forBook bookID: String) {
        references.removeValue(forKey: bookID)
        persistReferences()
    }

    /// The reading frontier in reference words — the furthest position the camera has proven the
    /// reader reached. Canonical text past this never enters any prompt.
    func alignedFrontier(forBook bookID: String) -> Int? {
        sessions.filter { $0.bookID == bookID }
            .flatMap(\.pages)
            .compactMap { $0.alignedRange?.upperBound }
            .max()
    }

    /// Record the reader's "I've read up to here": everything before the current camera-proven
    /// frontier counts as read (chapters read before the app, offline stretches between sittings).
    /// Clamped to the frontier by construction — an assertion can never reach past what the
    /// camera has witnessed. Returns the recorded position, or `nil` when there's no reference
    /// or no aligned capture yet to anchor "here".
    @discardableResult
    func assertCaughtUp(forBook bookID: String) -> Int? {
        guard var reference = references[bookID],
              let frontier = alignedFrontier(forBook: bookID), frontier > 0 else { return nil }
        reference.assertedReadUpTo = max(reference.assertedReadUpTo ?? 0, frontier)
        references[bookID] = reference
        persistReferences()
        return reference.assertedReadUpTo
    }

    /// The reference ranges the reader has covered, for retrieval grounding: asserted region +
    /// captured pages + **interpolated small holes**. Interpolation is deliberately narrow: a hole
    /// is covered only when it's smaller than `interpolationLimit` words AND flanked by aligned
    /// captures from the *same sitting* — the camera witnessed that sitting's continuity and
    /// merely blinked on a page (blur, empty OCR, a false dedup drop). Holes between sittings
    /// never interpolate, however small: there's no continuity evidence across a gap in time —
    /// that's what the catch-up assertion is for. Nothing here can exceed the camera frontier:
    /// every input range is at or behind it by construction.
    func coveredRanges(forBook bookID: String, interpolationLimit: Int = 800) -> [Range<Int>] {
        guard let reference = references[bookID] else { return [] }
        var ranges: [Range<Int>] = []
        if let asserted = reference.assertedReadUpTo, asserted > 0 {
            ranges.append(0..<asserted)
        }
        for session in sessions where session.bookID == bookID {
            let aligned = session.pages.compactMap(\.alignedRange).sorted { $0.lowerBound < $1.lowerBound }
            guard var current = aligned.first else { continue }
            for next in aligned.dropFirst() {
                if next.lowerBound <= current.upperBound + interpolationLimit {
                    current = current.lowerBound..<max(current.upperBound, next.upperBound)
                } else {
                    ranges.append(current)
                    current = next
                }
            }
            ranges.append(current)
        }
        // Merge overlaps across sources (no interpolation here — touching/overlapping only).
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The largest stretch behind the frontier that is neither camera-witnessed nor asserted —
    /// chapters read away from the app, or genuinely skipped. `nil` when there's no meaningful
    /// hole. This is what lets the assistant *ask* instead of wrongly answering "that hasn't
    /// come up yet" about a chapter the reader finished on the couch. (Small same-sitting holes
    /// are auto-covered by `coveredRanges` interpolation and sit below this floor anyway.)
    func unconfirmedGap(forBook bookID: String, minimumWords: Int = 1500) -> Range<Int>? {
        guard let reference = references[bookID],
              alignedFrontier(forBook: bookID) != nil else { return nil }
        let asserted = reference.assertedReadUpTo ?? 0
        let captured = sessions.filter { $0.bookID == bookID }
            .flatMap(\.pages)
            .compactMap(\.alignedRange)
            .sorted { $0.lowerBound < $1.lowerBound }

        var largest: Range<Int>?
        var covered = asserted
        for range in captured {
            if range.lowerBound > covered {
                let hole = covered..<range.lowerBound
                if hole.count >= minimumWords, hole.count > (largest?.count ?? 0) { largest = hole }
            }
            covered = max(covered, range.upperBound)
        }
        return largest
    }

    /// How far through the reference copy the reader is (0…1), derived from stored alignments —
    /// no book text needed, so "where was I?" can say it offline.
    func progress(forBook bookID: String) -> Double? {
        guard let reference = references[bookID], reference.wordCount > 0,
              let frontier = alignedFrontier(forBook: bookID) else { return nil }
        return min(1, Double(frontier) / Double(reference.wordCount))
    }

    // MARK: - Sessions

    @discardableResult
    func startSession(bookID: String, bookTitle: String, at date: Date = Date()) -> ReadingSession {
        let session = ReadingSession(bookID: bookID, bookTitle: bookTitle, startedAt: date)
        sessions.insert(session, at: 0)
        persistNow()
        return session
    }

    func endSession(id: String, at date: Date = Date()) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].endedAt = date
        persistNow()
    }

    func session(id: String) -> ReadingSession? { sessions.first { $0.id == id } }

    /// Sessions for one book, oldest-first — the order they were read in.
    func sessions(forBook bookID: String) -> [ReadingSession] {
        sessions.filter { $0.bookID == bookID }.sorted { $0.startedAt < $1.startedAt }
    }

    func deleteSession(id: String) {
        sessions.removeAll { $0.id == id }
        persistNow()
    }

    func deleteBook(id bookID: String) {
        sessions.removeAll { $0.bookID == bookID }
        persistNow()
    }

    // MARK: - Pages

    /// File a page against a session. Returns the capture, or `nil` if the session is unknown or
    /// the page is one this book already has.
    ///
    /// `pageIndex` is assigned book-scoped, so page numbering runs across sessions: picking a book
    /// back up on Tuesday continues Monday's count rather than restarting it. It is max+1, not
    /// count: after `deleteSession` removes a non-terminal session, count would collide with the
    /// surviving higher indices and the context block would carry two pages with the same number.
    @discardableResult
    func appendPage(text: String, dHash: UInt64, at date: Date = Date(), to sessionID: String,
                    alignment: BookAlignmentIndex.Match? = nil) -> PageCapture? {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let bookID = sessions[idx].bookID
        // Unsorted on purpose — this path needs only a max and membership, and it runs per capture.
        let priorPages = sessions.filter { $0.bookID == bookID }.flatMap(\.pages)
        guard !isDuplicate(text: text, dHash: dHash, among: priorPages) else {
            dedupDropCount += 1
            return nil
        }

        let nextIndex = (priorPages.map(\.pageIndex).max() ?? -1) + 1
        let capture = PageCapture(pageIndex: nextIndex, text: text, capturedAt: date, dHash: dHash,
                                  alignedStart: alignment?.wordRange.lowerBound,
                                  alignedWordCount: alignment.map(\.wordRange.count),
                                  alignedConfidence: alignment?.confidence)
        sessions[idx].pages.append(capture)
        scheduleCheckpoint()
        return capture
    }

    /// Every page of a book in reading order, across all its sessions — the grounding corpus.
    /// `capturedAt` breaks pageIndex ties (possible in data written before max+1 indexing), since
    /// Swift's sort is not guaranteed stable.
    func pages(forBook bookID: String) -> [PageCapture] {
        sessions.filter { $0.bookID == bookID }
            .flatMap(\.pages)
            .sorted { $0.pageIndex != $1.pageIndex ? $0.pageIndex < $1.pageIndex : $0.capturedAt < $1.capturedAt }
    }

    /// Whether this book has already seen this page. Two signals, because either alone has a blind
    /// spot: the hash catches a re-look whose OCR came out differently, and the text catches a
    /// re-look from a new angle or distance whose hash therefore drifted.
    ///
    /// The hash signal is trusted alone only inside `hashDedupWindow` (a re-look is at recent
    /// pages); against the whole book a bare 9×8-dhash match is as likely a layout collision
    /// between two dense prose pages as a real re-look, and acting on it silently drops a page.
    private func isDuplicate(text: String, dHash: UInt64, among pages: [PageCapture]) -> Bool {
        let normalized = ReadingText.normalized(text)
        let textComparable = normalized.count >= Self.minimumTextMatchLength
        let hashWindowFloor = (pages.map(\.pageIndex).max() ?? -1) - Self.hashDedupWindow + 1
        return pages.contains { page in
            if page.pageIndex >= hashWindowFloor,
               PerceptualHash.hamming(page.dHash, dHash) <= duplicateHashDistance { return true }
            guard textComparable else { return false }
            // Cheap pre-filter before normalizing the stored page: normalization only collapses
            // whitespace, so texts whose raw lengths differ wildly can't normalize equal.
            guard abs(page.text.count - text.count) <= max(page.text.count, text.count) / 2 else { return false }
            return ReadingText.normalized(page.text) == normalized
        }
    }

    // MARK: - Derived stats

    /// Books this reader has sessions for, most recently read first.
    func books() -> [(id: String, title: String)] {
        var seen = Set<String>()
        return sessions
            .sorted { $0.startedAt > $1.startedAt }
            .compactMap { seen.insert($0.bookID).inserted ? (id: $0.bookID, title: $0.bookTitle) : nil }
    }

    /// Derived stats for one book. `nil` when the book has no sessions.
    func stats(forBook bookID: String) -> ReadingStats? {
        let bookSessions = sessions(forBook: bookID)
        guard let latest = bookSessions.last else { return nil }

        let pageCount = bookSessions.reduce(0) { $0 + $1.pages.count }
        let totalMinutes = bookSessions.reduce(0) { $0 + $1.durationMinutes }
        let lastReadAt = bookSessions.compactMap { $0.endedAt ?? $0.pages.last?.capturedAt }.max()

        return ReadingStats(
            bookID: bookID,
            bookTitle: latest.bookTitle,
            sessionCount: bookSessions.count,
            pageCount: pageCount,
            totalMinutes: totalMinutes,
            pagesPerMinute: totalMinutes > 0 ? Double(pageCount) / totalMinutes : 0,
            lastReadAt: lastReadAt)
    }

    // MARK: - Persistence

    /// Save suppression after a read failure on an existing file (the on-disk data may be intact —
    /// never overwrite what we couldn't read).
    private var saveBlocked = false

    /// Every persist rewrites the whole corpus (all books, all pages of OCR text), so a write per
    /// page turn is the store's dominant cost and it grows with the library. Page appends therefore
    /// coalesce into a checkpoint at most this often; session lifecycle events (start/end/delete)
    /// persist immediately and cancel any pending checkpoint. Crash window: at most this many
    /// seconds of one live session's pages. `0` persists synchronously (tests).
    var checkpointInterval: TimeInterval = 60
    private var checkpointTask: Task<Void, Never>?

    /// Separate suppression flag for the references file (same invariant as `saveBlocked`).
    private var referencesSaveBlocked = false

    private func load() {
        switch JSONStore.loadArray(ReadingSession.self, at: sessionsURL, name: "reading_sessions") {
        case .loaded(let s), .recovered(let s, _): sessions = s
        case .corrupt: sessions = []          // original preserved in StoreRecovery
        case .unreadable: saveBlocked = true
        case .absent: break
        }
        switch JSONStore.loadDictionary(BookReference.self, at: referencesURL, name: "reading_references") {
        case .loaded(let r), .recovered(let r, _): references = r
        case .corrupt: references = [:]
        case .unreadable: referencesSaveBlocked = true
        case .absent: break
        }
    }

    private func persistReferences() {
        guard !referencesSaveBlocked else {
            PrivacyLog.store(.readingSessions, .saveSkipped, slot: PrivacyToken("reading_references"))
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(references).write(to: referencesURL, options: .atomic)
            protectIfNeeded(referencesURL)
        } catch {
            PrivacyLog.store(.readingSessions, .saveFailed, slot: PrivacyToken("reading_references"),
                             error: SafeErrorSummary(error))
        }
    }

    private func scheduleCheckpoint() {
        guard checkpointInterval > 0 else { return persistNow() }
        guard checkpointTask == nil else { return }   // one pending checkpoint is enough
        let interval = checkpointInterval
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.checkpointTask = nil
            self.persist()
        }
    }

    /// Immediate persist for lifecycle events; supersedes any pending checkpoint.
    private func persistNow() {
        checkpointTask?.cancel()
        checkpointTask = nil
        persist()
    }

    private func persist() {
        guard !saveBlocked else {
            PrivacyLog.store(.readingSessions, .saveSkipped, slot: PrivacyToken("reading_sessions"))
            return
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(sessions).write(to: sessionsURL, options: .atomic)
            protectIfNeeded(sessionsURL)
        } catch {
            PrivacyLog.store(.readingSessions, .saveFailed, slot: PrivacyToken("reading_sessions"),
                             error: SafeErrorSummary(error))
        }
    }

    /// Camera-derived text follows the same at-rest posture as camera-derived video
    /// (`HIPAAComplianceService.protectFile`): complete file protection + no iCloud backup when
    /// compliance mode is on. New sessions can't start under `hipaaMode` (the tool is in
    /// `hipaaDisabledTools` and the service guards), so this covers data captured before the
    /// mode was enabled.
    private func protectIfNeeded(_ url: URL) {
        guard Config.hipaaMode else { return }
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}
