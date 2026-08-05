import Foundation

/// The single persistence boundary for the shared `saved_notes` key.
///
/// Historically two tools wrote this key with different schemas: `MeetingSummaryTool` stored
/// `[[String: String]]` dictionaries while `FitnessCoachingTool` stored plain `[String]` lines.
/// Whichever wrote second made the other's `as?` cast fail, so its next write started from an
/// empty array and silently destroyed the existing notes. Every reader and writer now goes
/// through this store, which speaks the canonical dictionary schema and migrates legacy
/// string entries on read.
enum SavedNotesStore {
    /// Internal so tests can seed legacy values without duplicating the on-disk key literal.
    static let storageKey = "saved_notes"

    static func load(defaults: UserDefaults = .standard) -> [[String: String]] {
        guard let rawNotes: [Any] = defaults.array(forKey: storageKey) else { return [] }

        var convertedLegacyEntry = false
        let notes = rawNotes.compactMap { rawNote -> [String: String]? in
            if let note = rawNote as? [String: String] {
                return note
            }
            if let legacyNote = rawNote as? String {
                convertedLegacyEntry = true
                return migrate(legacyNote)
            }
            return nil
        }

        // Persist only when migration actually occurred. A canonical read remains read-only.
        if convertedLegacyEntry {
            defaults.set(notes, forKey: storageKey)
        }

        return notes
    }

    static func save(
        _ notes: [[String: String]],
        defaults: UserDefaults = .standard
    ) {
        defaults.set(Array(notes.suffix(50)), forKey: storageKey)
    }

    static func append(
        title: String,
        content: String,
        date: String,
        defaults: UserDefaults = .standard
    ) {
        var notes = load(defaults: defaults)
        notes.append([
            "title": title,
            "content": content,
            "date": date,
        ])
        save(notes, defaults: defaults)
    }

    private static func migrate(_ legacyNote: String) -> [String: String] {
        let split = splitDatePrefix(from: legacyNote)
        var content = split.content
        let parsedDate = split.dateText.flatMap(parseLegacyDate)

        let title: String
        let workoutPrefix = "Workout: "
        if content.hasPrefix(workoutPrefix) {
            content.removeFirst(workoutPrefix.count)
            if let dateText = split.dateText, !dateText.isEmpty {
                title = "Workout Note — \(dateText)"
            } else {
                title = "Workout Note"
            }
        } else {
            title = String(content.prefix(60))
        }

        var note = [
            "title": title,
            "content": content,
        ]
        if let parsedDate {
            note["date"] = ISO8601DateFormatter().string(from: parsedDate)
        }
        return note
    }

    private static func splitDatePrefix(from legacyNote: String) -> (dateText: String?, content: String) {
        guard legacyNote.hasPrefix("["),
              let closingBracket = legacyNote.range(of: "] ") else {
            return (nil, legacyNote)
        }

        let dateStart = legacyNote.index(after: legacyNote.startIndex)
        let dateText = String(legacyNote[dateStart..<closingBracket.lowerBound])
        let content = String(legacyNote[closingBracket.upperBound...])
        return (dateText, content)
    }

    private static func parseLegacyDate(_ dateText: String) -> Date? {
        // The original writer used the current locale. The fallbacks also cover notes
        // migrated after a locale change, including the historical UK day-first form.
        let localeIdentifiers = [
            Locale.current.identifier,
            "en_GB",
            "en_US",
        ]

        for localeIdentifier in localeIdentifiers {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: localeIdentifier)
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            if let date = formatter.date(from: dateText) {
                return date
            }
        }
        return nil
    }
}
