import Foundation

/// An agenda found in a calendar event, offered to the wearer when the event starts.
struct MeetingAgendaOffer: Equatable {
    let title: String
    let items: [String]
    let endsAt: Date
}

/// Decides what in a calendar event's notes counts as an agenda. Pure.
///
/// Invite notes are mostly written by someone else and mostly aren't agendas — greetings, join
/// links, dial-in numbers — so plain lines never count. The rule is about shape rather than
/// words, because notes arrive in any language: the agenda is the first run of at least
/// `minimumItems` list items, and only those items are taken from the notes.
///
/// - An item is a bullet, or a number followed by `.`, `)` or `、`, at the start of a line, then a
///   space (none is needed after `、`), then text with at least one letter.
/// - Blank lines between items don't end a run. Lines indented past the run's first item are that
///   item's detail and are skipped. Any other line ends it, as does a change of marker.
/// - Numbered items must count up by one, so "10. Bring laptops" or a date isn't a list.
/// - A run with a link in it is dropped whole: that shape is join details far more often than a
///   plan, and a partial agenda would be worse than no offer.
enum MeetingAgenda {
    static let minimumItems = 2

    /// The id of the current meeting's agenda in the playbook store. A colon can't appear in an
    /// id made from a name, so this never meets a wearer's playbook.
    static let playbookID = "calendar:agenda"

    /// The offer for an event, or nil when offers are off or its notes hold no agenda.
    static func offer(title: String, notes: String?, endsAt: Date, enabled: Bool) -> MeetingAgendaOffer? {
        guard enabled, let notes else { return nil }
        let found = items(in: notes)
        guard !found.isEmpty else { return nil }
        return MeetingAgendaOffer(title: title, items: found, endsAt: endsAt)
    }

    /// The agenda items in `notes`, or empty when there is no agenda.
    static func items(in notes: String) -> [String] {
        var run = Run()
        for line in notes.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if !run.items.isEmpty, indent > run.indent { continue }

            if let item = ListItem(text), run.accepts(item) {
                run.add(item, indent: indent)
            } else {
                if run.isAgenda { return run.items }
                run = Run()
                if let item = ListItem(text) { run.add(item, indent: indent) }
            }
        }
        return run.isAgenda ? run.items : []
    }

    // MARK: - Saved by earlier versions

    /// Whether this is a playbook an earlier version saved from a calendar event. Those carry no
    /// mark, but they are exact: the event's notes as reference text, and one bare step for each
    /// of its non-empty lines. A playbook edited since then no longer matches and stays the
    /// wearer's. Reads `legacySteps` alone, so it keeps working whatever `items(in:)` becomes.
    static func wasSavedFromCalendar(_ playbook: Playbook) -> Bool {
        guard playbook.icon == legacyIcon,
              !playbook.referenceText.isEmpty,
              playbook.steps.count >= minimumItems,
              playbook.steps.allSatisfy({ $0.type == .prompt && $0.detail.isEmpty }) else { return false }
        return playbook.steps.map(\.title) == legacySteps(from: playbook.referenceText)
    }

    private static let legacyIcon = "person.3"

    /// The line parser those versions used, kept only to recognise what it made.
    private static func legacySteps(from notes: String) -> [String] {
        notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                var cleaned = line
                if let match = cleaned.range(of: #"^[\-\•\*]\s+"#, options: .regularExpression) {
                    cleaned = String(cleaned[match.upperBound...])
                } else if let match = cleaned.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                    cleaned = String(cleaned[match.upperBound...])
                }
                return cleaned.isEmpty ? nil : cleaned
            }
    }
}

// MARK: - Parsing

private extension MeetingAgenda {
    struct ListItem {
        enum Marker: Equatable {
            case bullet(Character)
            case number(Int)
        }

        let marker: Marker
        let text: String

        init?(_ line: String) {
            guard let (marker, text) = Self.bullet(in: line) ?? Self.number(in: line) else { return nil }
            guard text.contains(where: \.isLetter) else { return nil }
            self.marker = marker
            self.text = text
        }

        var hasLink: Bool {
            let lowered = text.lowercased()
            return lowered.contains("://") || lowered.contains("www.")
        }

        private static let bullets: Set<Character> = ["-", "*", "•", "·", "‣", "◦", "▪", "–", "・"]

        private static func bullet(in line: String) -> (Marker, String)? {
            guard let first = line.first, bullets.contains(first) else { return nil }
            let rest = line.dropFirst()
            guard rest.first?.isWhitespace == true else { return nil }
            return (.bullet(first), rest.trimmingCharacters(in: .whitespaces))
        }

        private static func number(in line: String) -> (Marker, String)? {
            let digits = line.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 2, let value = Int(digits) else { return nil }
            let rest = line.dropFirst(digits.count)
            guard let punctuation = rest.first else { return nil }
            let body = rest.dropFirst()
            switch punctuation {
            case ".", ")": guard body.first?.isWhitespace == true else { return nil }
            case "、": break
            default: return nil
            }
            return (.number(value), body.trimmingCharacters(in: .whitespaces))
        }
    }

    struct Run {
        private(set) var items: [String] = []
        private(set) var indent = 0
        private var lastMarker: ListItem.Marker?
        private var hasLink = false

        var isAgenda: Bool { items.count >= MeetingAgenda.minimumItems && !hasLink }

        func accepts(_ item: ListItem) -> Bool {
            guard let lastMarker else { return true }
            switch (lastMarker, item.marker) {
            case let (.bullet(previous), .bullet(next)): return previous == next
            case let (.number(previous), .number(next)): return next == previous + 1
            default: return false
            }
        }

        mutating func add(_ item: ListItem, indent: Int) {
            if items.isEmpty { self.indent = indent }
            items.append(item.text)
            lastMarker = item.marker
            hasLink = hasLink || item.hasLink
        }
    }
}
