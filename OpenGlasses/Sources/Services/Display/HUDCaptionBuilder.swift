import Foundation

/// One caption frame on the lens (Plan LC §6): up to three rows of what is being said, who is
/// saying it when diarization names them, and whether capture is live. Equatable, so the render
/// queue's latest-wins de-duplication skips a frame identical to the one on the lens. Never logged:
/// the rows are what people near the wearer said.
struct HUDCaption: Equatable {
    /// The rows, oldest first, each at most `HUDCaptionBuilder.rowLength` characters.
    var rows: [String]
    /// The diarized speaker's label ("Alice", "Speaker 2"), or nil on the unlabelled paths.
    var speaker: String?
    /// Capture is live (the mic is open for captions), so the frame carries the mic mark.
    var listening: Bool
}

/// Plan LC §6 (Plan BY on the lens): the caption screen. Captions used to reach the lens as one
/// condensed line — `showText`, cut to `HUDTextShaper.maxBodyLength` (120 characters), which on a
/// conversation is barely a sentence and jumps to empty at every final. Now a caption is a frame of
/// its own, budgeted to `budget` (340) characters in `rowCount` (3) rows:
///
/// - **The newest text is kept.** The live partial follows the last few final captions of the same
///   speaker (within `carryOver` seconds), so a final does not blank the lens; when it all runs past
///   the budget the oldest words are dropped, at a word boundary, and the first row says "…".
/// - **Rows wrap forward**, at word boundaries, from the start of the carried text, and only the
///   last three are shown, so a row stays where it is while the next one fills — rolling captions,
///   not a reflow on every word.
/// - **The speaker** is a meta line above the rows when diarization names one; **the mic mark**
///   (`HUDIcon.microphone`) leads that line, or the first row without one, while capture is live.
/// - **Top-aligned**: the backend draws the rows from the top of the column, where the old line was.
///
/// Each row is at most `rowLength` (113) characters, under `HUDTextShaper.maxBodyLength`, so the
/// backend's own per-line condense never cuts one. Pure: no display, no clock of its own.
/// Still ambient: `GlassesDisplayService.showCaption` drops it under any interactive screen and
/// while the wearer has dismissed the lens, and P1's pacer spaces the sends.
enum HUDCaptionBuilder {
    /// Characters on the lens at most (Plan LC §6).
    static let budget = 340
    /// Rows on the lens at most.
    static let rowCount = 3
    /// Characters a row holds at most: the budget shared by the rows.
    static var rowLength: Int { budget / rowCount }
    /// A final caption older than this is not carried in front of the live text.
    static let carryOver: TimeInterval = 12
    /// How many recent finals are considered for carrying.
    static let carriedFinals = 3

    /// A final caption the service already holds, newest last.
    struct Final: Equatable {
        let text: String
        let at: Date
        let speaker: String?
    }

    /// The caption for the live text, or nil when there is nothing to show.
    static func caption(live: String, speaker: String?, recent: [Final], now: Date,
                        listening: Bool) -> HUDCaption? {
        let carried = text(live: live, speaker: speaker, recent: recent, now: now)
        let rows = rows(carried)
        guard !rows.isEmpty else { return nil }
        let label = speaker.map(collapse).flatMap { $0.isEmpty ? nil : $0 }
        return HUDCaption(rows: rows, speaker: label, listening: listening)
    }

    /// The text to caption: the recent finals of the same speaker inside `carryOver` (oldest first),
    /// then the live text. A final the live text already begins with (a compacted caption that
    /// carries its own continuation) is not repeated.
    static func text(live: String, speaker: String?, recent: [Final], now: Date) -> String {
        let liveText = collapse(live)
        var parts: [String] = []
        for final in recent.suffix(carriedFinals) {
            let text = collapse(final.text)
            guard !text.isEmpty, final.speaker == speaker,
                  now.timeIntervalSince(final.at) <= carryOver, now >= final.at else { continue }
            guard !liveText.hasPrefix(text) else { continue }
            parts.append(text)
        }
        if !liveText.isEmpty { parts.append(liveText) }
        return parts.joined(separator: " ")
    }

    /// `text` as rows of at most `rowLength`, wrapped forward at word boundaries, keeping the last
    /// `rowCount`. A word longer than a row is split. When anything was dropped, the first row
    /// starts with "… " (a word comes off it if the mark would not fit). Empty for empty text.
    static func rows(_ text: String) -> [String] {
        let words = collapse(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var rows: [String] = []
        var current = ""
        for var word in words {
            while word.count > rowLength {
                if !current.isEmpty { rows.append(current); current = "" }
                rows.append(String(word.prefix(rowLength)))
                word = String(word.dropFirst(rowLength))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= rowLength {
                current += " " + word
            } else {
                rows.append(current)
                current = word
            }
        }
        if !current.isEmpty { rows.append(current) }
        guard rows.count > rowCount else { return rows }
        var kept = Array(rows.suffix(rowCount))
        var first = kept[0]
        while first.count + 2 > rowLength, let space = first.firstIndex(of: " ") {
            first = String(first[first.index(after: space)...])
        }
        kept[0] = first.count + 2 <= rowLength ? "… " + first : first
        return kept
    }

    /// The caption's lines: the speaker (meta, with the mic mark while live) over the rows; without
    /// a speaker the mic mark leads the first row.
    static func lines(_ caption: HUDCaption) -> [HUDLine] {
        var lines: [HUDLine] = []
        let mark: HUDIcon = caption.listening ? .microphone : .none
        if let speaker = caption.speaker {
            lines.append(HUDLine(speaker, icon: mark, emphasis: .meta))
            lines += caption.rows.map { HUDLine($0) }
        } else {
            for (index, row) in caption.rows.enumerated() {
                lines.append(HUDLine(row, icon: index == 0 ? mark : .none))
            }
        }
        return lines
    }

    /// The caption as an items-less screen: what the Meta backend draws (top-aligned, no buttons)
    /// and what the web mirror shows. Not interactive, so it never takes the lens from anything.
    static func screen(_ caption: HUDCaption) -> HUDScreen {
        HUDScreen(title: nil, lines: lines(caption), items: [])
    }

    /// A backend that draws only a heading and a body (Even G2, the default) gets the speaker as
    /// the heading and the rows as one body, which it wraps to its own panel.
    static func body(_ caption: HUDCaption) -> String {
        caption.rows.joined(separator: " ")
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
