import Foundation

/// One kept captions or translation session (Plan KP §7, P5): what was said, line by line, from
/// the moment captions started to the moment they stopped.
///
/// Written by `CaptionSessionStore` only while **Keep caption sessions** is on, never in Medical
/// Compliance mode. It is other people's speech, so it never goes to a model, to memory or to
/// `BrainStore` unless the wearer asks for it; nothing here or in the store feeds any of them.
struct CaptionSession: Codable, Equatable, Identifiable {

    /// One finished caption. `said` is what was heard; when the session translated, it is the
    /// words in the language they were spoken and `translation` is what the wearer read.
    struct Turn: Codable, Equatable {
        let at: Date
        let said: String
        var translation: String?
        /// The speaker's name, or "Speaker 2" for a voice nobody named, where diarisation
        /// labelled the caption. Nil when it did not.
        var speaker: String?
    }

    let id: UUID
    /// When captions started. The file is named by it, and the seven days count from it.
    let startedAt: Date
    let endedAt: Date
    let turns: [Turn]

    /// Whether any line carries a translation.
    var translated: Bool { turns.contains { $0.translation != nil } }

    /// Whether the session's words mention `token` anywhere: what was said, its translation or the
    /// speaker's name. The subject erasure's test.
    func mentions(_ token: String) -> Bool {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return turns.contains { turn in
            [turn.said, turn.translation, turn.speaker].contains {
                $0?.localizedCaseInsensitiveContains(needle) == true
            }
        }
    }
}

/// Collects a session's finished captions while captions run (Plan KP P5). Pure: the caption
/// service hands it each final caption, and `finish` turns them into a `CaptionSession`.
///
/// It keeps the speaker's *id*, not a name, until the end, so a voice named halfway through the
/// session carries its name on every line it spoke.
struct CaptionSessionRecorder {

    /// A session longer than this stops collecting; what it has is still kept. About eight hours
    /// of steady conversation.
    static let turnCap = 5000

    struct Pending: Equatable {
        let at: Date
        let text: String
        let original: String?
        let speaker: Int?
    }

    let id: UUID
    let startedAt: Date
    private(set) var pending: [Pending] = []

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    /// A finished caption. `text` is what the caption showed; `original` the source-language words
    /// when it was a translation.
    mutating func append(text: String, original: String?, speaker: Int?, at: Date) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pending.count < Self.turnCap else { return }
        let source = original?.trimmingCharacters(in: .whitespacesAndNewlines)
        pending.append(Pending(at: at, text: trimmed, original: source?.isEmpty == false ? source : nil,
                               speaker: speaker))
    }

    /// The session as kept, or nil when nothing was said.
    func finish(at end: Date, speakerLabel: (Int) -> String) -> CaptionSession? {
        guard !pending.isEmpty else { return nil }
        let turns = pending.map { line -> CaptionSession.Turn in
            // A translated caption: the words as spoken first, what the wearer read under them.
            if let original = line.original {
                return .init(at: line.at, said: original, translation: line.text,
                             speaker: line.speaker.map(speakerLabel))
            }
            return .init(at: line.at, said: line.text, translation: nil,
                         speaker: line.speaker.map(speakerLabel))
        }
        return CaptionSession(id: id, startedAt: startedAt, endedAt: max(end, startedAt), turns: turns)
    }
}

/// The plain text a kept session shares as (Plan KP §7): a heading, then one turn per line as
/// `HH:mm  said`, the speaker's name before the words where diarisation labelled them, and the
/// translation on the line under it, lined up with the words.
enum CaptionSessionTranscript {

    /// The gap after the time, and the indent the translation line takes to sit under the words.
    static let separator = "  "
    static let translationIndent = String(repeating: " ", count: 5) + separator

    static func plainText(_ session: CaptionSession, timeZone: TimeZone = .current,
                          locale: Locale = .current) -> String {
        var lines = [heading(session, timeZone: timeZone, locale: locale), ""]
        for turn in session.turns {
            lines.append(line(turn, timeZone: timeZone))
            if let translation = turn.translation {
                lines.append(translationIndent + translation)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One turn's first line: `08:30  Alice: what she said`.
    static func line(_ turn: CaptionSession.Turn, timeZone: TimeZone = .current) -> String {
        let words = turn.speaker.map { "\($0): \(turn.said)" } ?? turn.said
        return time(turn.at, timeZone: timeZone) + separator + words
    }

    /// `HH:mm`, the same in every locale, so the column lines up.
    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func heading(_ session: CaptionSession, timeZone: TimeZone = .current,
                        locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        let began = formatter.string(from: session.startedAt)
        return session.translated
            ? String(localized: "Translated captions, \(began)")
            : String(localized: "Captions, \(began)")
    }
}
