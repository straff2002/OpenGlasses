import CryptoKit
import Foundation

// MARK: - Plan BQ P2 — per-store content adapters (pure)
//
// Each adapter maps one store's decoded contents to `[IndexableRecord]`. Pure functions
// over injected values — the live gather in `SiriContentProvider` does the actual
// UserDefaults/file/store reads, tests pass fixtures. Where a store's model is
// file-private (`NotesTool.SavedNote`, `SaveLocationTool.SavedLocation`) a matching
// `Codable` mirror is declared here and decoded off the same UserDefaults key with the
// same default-strategy `JSONDecoder`.

/// Mirrors `NotesTool.SavedNote` (private there) — UserDefaults key `nativeTool_savedNotes`.
struct StoredQuickNote: Codable, Equatable {
    let title: String?
    let content: String
    let timestamp: Date
    /// `SavedNoteOrigin` — `"assistant"` for every note `save_note` writes; nil on older notes.
    var origin: String? = nil
}

/// Mirrors `SaveLocationTool.SavedLocation` (private there) — key `saved_locations`.
struct StoredSavedLocation: Codable, Equatable {
    let label: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let timestamp: Date
}

/// Title/summary metadata of a conversation thread — deliberately NOT the whole
/// `ConversationThread`, so message bodies can never leak into the index by construction.
struct ConversationSummaryInput: Equatable {
    let id: String
    let title: String
    let summary: String?
    let updatedAt: Date
}

enum SiriContentAdapters {

    /// Quick notes have no stored id → content-hash id. Documented limitation: editing a
    /// note re-creates its index entry (old id is planned as a deletion, new as an upsert).
    static func notes(quick: [StoredQuickNote], contextual: [ContextualNote]) -> [IndexableRecord] {
        var out: [IndexableRecord] = []
        for note in quick {
            let title = note.title?.isEmpty == false
                ? note.title!
                : String(note.content.prefix(60))
            out.append(IndexableRecord(
                contentType: .note,
                itemId: stableId(title, note.content, note.timestamp),
                title: title,
                text: note.content,
                keywords: [],
                date: note.timestamp
            ))
        }
        for note in contextual {
            out.append(IndexableRecord(
                contentType: .note,
                itemId: note.id,
                title: String(note.content.prefix(60)),
                text: note.content,
                keywords: note.tags + [note.locationName].compactMap { $0 },
                date: note.createdAt
            ))
        }
        return out
    }

    /// Meeting summaries share the generic `saved_notes` key with other note writers —
    /// filter by the `MeetingSummaryTool` title prefix, don't migrate the store (plan BQ).
    static let meetingSummaryTitlePrefix = "Meeting Summary"

    static func meetingSummaries(rawSavedNotes: [[String: String]]) -> [IndexableRecord] {
        let iso = ISO8601DateFormatter()
        return rawSavedNotes.compactMap { dict in
            guard let title = dict["title"], title.hasPrefix(meetingSummaryTitlePrefix),
                  let content = dict["content"] else { return nil }
            let date = dict["date"].flatMap { iso.date(from: $0) }
            return IndexableRecord(
                contentType: .meetingSummary,
                itemId: stableId(title, dict["date"] ?? ""),
                title: title,
                text: content,
                keywords: ["meeting"],
                date: date
            )
        }
    }

    static func savedLocations(_ locations: [StoredSavedLocation]) -> [IndexableRecord] {
        locations.map { location in
            IndexableRecord(
                contentType: .savedLocation,
                itemId: stableId(location.label, location.timestamp),
                title: location.label,
                text: location.address
                    ?? String(format: "%.5f, %.5f", location.latitude, location.longitude),
                keywords: [location.label, "location", "spot"],
                date: location.timestamp
            )
        }
    }

    static func teleprompterScripts(_ scripts: [SavedScript]) -> [IndexableRecord] {
        scripts.map { script in
            IndexableRecord(
                contentType: .teleprompterScript,
                itemId: script.id.uuidString,
                title: script.title,
                text: script.text,
                keywords: ["script", "teleprompter"],
                date: script.updatedAt
            )
        }
    }

    static func playbooks(_ playbooks: [Playbook]) -> [IndexableRecord] {
        playbooks.map { playbook in
            let stepText = playbook.steps.map(\.title).joined(separator: ". ")
            return IndexableRecord(
                contentType: .playbook,
                itemId: playbook.id,
                title: playbook.name,
                text: [stepText, String(playbook.referenceText.prefix(500))]
                    .filter { !$0.isEmpty }.joined(separator: "\n"),
                keywords: ["playbook"],
                date: playbook.createdAt
            )
        }
    }

    static func studyDecks(_ decks: [StudyDeck]) -> [IndexableRecord] {
        decks.map { deck in
            IndexableRecord(
                contentType: .studyDeck,
                itemId: deck.id,
                title: deck.summary.title,
                text: ([deck.summary.overview] + deck.summary.keyPoints).joined(separator: "\n"),
                keywords: ["study", "flashcards"] + [deck.source].compactMap { $0 },
                date: deck.createdAt
            )
        }
    }

    /// Excerpt cap for a donated reading session, matching the playbook adapter's posture. Recall
    /// ("the Hobbit I read on Tuesday") rides the title/keywords/date; donating the whole corpus
    /// meant every foreground refresh re-joined and SHA256-hashed a forever-growing body of prose —
    /// and put verbatim pages of whatever the user reads into the system index.
    static let readingSessionExcerptLimit = 500

    /// One record per sitting, so "the Hobbit I read on Tuesday" is findable (Plan BT). The text is
    /// a bounded excerpt of the reader's own captured pages — their book, their camera — which is
    /// why this is default-on where conversations and field sessions aren't. Sessions with no
    /// readable pages are skipped: a Spotlight hit with nothing behind it is worse than no hit.
    static func readingSessions(_ sessions: [ReadingSession]) -> [IndexableRecord] {
        sessions.compactMap { session in
            // Stop normalizing once the excerpt is full — this runs for every session on every
            // index refresh, so the work has to be bounded, not just the output.
            var text = ""
            for page in session.pages.sorted(by: { $0.pageIndex < $1.pageIndex }) {
                let normalized = ReadingText.normalized(page.text)
                guard !normalized.isEmpty else { continue }
                text += (text.isEmpty ? "" : "\n") + normalized
                if text.count >= readingSessionExcerptLimit { break }
            }
            guard !text.isEmpty else { return nil }
            return IndexableRecord(
                contentType: .readingSession,
                itemId: session.id,
                title: "\(session.bookTitle) — \(session.pages.count) page\(session.pages.count == 1 ? "" : "s")",
                text: String(text.prefix(readingSessionExcerptLimit)),
                keywords: ["reading", "book", session.bookTitle],
                date: session.startedAt
            )
        }
    }

    /// Titles-only by construction — the input type has no message bodies.
    static func conversations(_ threads: [ConversationSummaryInput]) -> [IndexableRecord] {
        threads.map { thread in
            IndexableRecord(
                contentType: .conversation,
                itemId: thread.id,
                title: thread.title,
                text: thread.summary ?? "",
                keywords: ["conversation"],
                date: thread.updatedAt
            )
        }
    }

    /// Metadata only, completed sessions only, opted-in vaults only. Never the audit log,
    /// transcript, or captured values — the full report stays behind the encrypted vault;
    /// the index entry is just enough to *find* it ("the compressor job from Tuesday").
    static func fieldSessions(
        _ sessions: [FieldSession],
        allowedVaults: Set<String>
    ) -> [IndexableRecord] {
        sessions.compactMap { session in
            guard session.endedAt != nil, allowedVaults.contains(session.vaultId) else {
                return nil
            }
            let asset = session.assetId ?? "Field session"
            let dateText = session.endedAt.map {
                DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none)
            } ?? ""
            return IndexableRecord(
                contentType: .fieldSession,
                itemId: session.id,
                title: [asset, dateText].filter { !$0.isEmpty }.joined(separator: " — "),
                text: "Outcome: \(session.outcome.rawValue). Vault: \(session.vaultId).",
                keywords: [session.vaultId, session.outcome.rawValue]
                    + [session.assetId].compactMap { $0 },
                date: session.endedAt
            )
        }
    }

    /// Deterministic id for stores whose records carry no stable identifier. SHA256-based —
    /// `String.hashValue` is randomly seeded per launch and would churn the whole index.
    private static func stableId(_ parts: String..., date: Date? = nil) -> String {
        var joined = parts.joined(separator: "|")
        if let date { joined += "|\(date.timeIntervalSince1970)" }
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func stableId(_ a: String, _ b: String, _ date: Date) -> String {
        stableId(a, b, date: date)
    }

    private static func stableId(_ a: String, _ date: Date) -> String {
        stableId(a, date: date)
    }
}
