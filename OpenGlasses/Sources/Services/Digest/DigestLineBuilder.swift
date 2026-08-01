import Foundation

/// Plan BZ — one legible line per digest item. Builds both halves of the rewrite contract:
/// the LLM prompt (style rules, terse lines) AND the deterministic fallback used verbatim when
/// the LLM is unavailable, offline, or suppressed by power policy. A bad rewrite falls back to
/// the template — it never blanks a line.
enum DigestLineBuilder {

    /// Per-line character budget for the HUD panel (a hardware read may retune this).
    static let maxLineLength = 44

    // MARK: - Deterministic fallback

    /// `[Calendar] Standup in 8 min` — the guaranteed floor.
    static func fallbackLine(for item: DigestItem, now: Date) -> String {
        var body = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let event = item.eventDate {
            body += " \(relativePhrase(from: now, to: event))"
        }
        return clampLength("[\(item.source.displayTag)] \(body)")
    }

    /// "in 8 min" / "now" / "in 2 h" / "started" — deterministic, tested at boundaries.
    static func relativePhrase(from now: Date, to event: Date) -> String {
        let seconds = event.timeIntervalSince(now)
        if seconds < -60 { return "(started)" }
        if seconds < 90 { return "now" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "in \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        return "in \(hours) h"
    }

    // MARK: - Rewrite prompt

    /// One prompt for the whole digest. The model returns `{"lines": [...]}` (via the
    /// structured-call path), one line per input item, same order.
    static func rewritePrompt(for digest: Digest, now: Date) -> String {
        let source = digest.items.enumerated().map { index, item in
            "\(index + 1). \(fallbackLine(for: item, now: now)) — \(item.rawBody.isEmpty ? item.title : item.rawBody)"
        }.joined(separator: "\n")
        return """
        Rewrite each notification below as ONE terse glanceable line for a tiny heads-up \
        display (max \(maxLineLength) characters).
        Rules:
        - State the thing; don't narrate. Never start with "You have" or "There is".
        - Keep the actionable verb and any time ("Standup in 8 min", "Reply to Sam").
        - Keep names, numbers, and places exactly.
        - One line per numbered item, same order, no numbering in the output.

        Items:
        \(source)
        """
    }

    /// JSON schema for the structured rewrite call.
    static func rewriteSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "lines": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["lines"]
        ]
    }

    // MARK: - Rewrite validation

    /// Accept a rewritten line only if it's usable as-is: non-empty, free of control
    /// characters, and within the length cap. Anything else → the deterministic template.
    static func clampRewrite(_ line: String?, fallback: String) -> String {
        guard let line else { return fallback }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return fallback
        }
        guard trimmed.count <= maxLineLength else { return fallback }
        return trimmed
    }

    /// Map a full rewrite response onto the digest: wrong line count → all fallbacks (the
    /// pairing is untrustworthy); otherwise clamp per line.
    static func lines(for digest: Digest, rewritten: [String]?, now: Date) -> [String] {
        let fallbacks = digest.items.map { fallbackLine(for: $0, now: now) }
        guard let rewritten, rewritten.count == digest.items.count else { return fallbacks }
        return zip(rewritten, fallbacks).map { clampRewrite($0, fallback: $1) }
    }

    /// The spoken form: lines joined into one short utterance, plus overflow.
    static func spokenDigest(lines: [String], overflowCount: Int) -> String? {
        guard !lines.isEmpty else { return nil }
        var spoken = lines.map { line in
            // Strip the "[Tag] " prefix for speech — the tag is a visual affordance.
            line.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        }.joined(separator: ". ")
        if overflowCount > 0 {
            spoken += ". And \(overflowCount) more."
        }
        return spoken
    }

    private static func clampLength(_ line: String) -> String {
        guard line.count > maxLineLength else { return line }
        return String(line.prefix(maxLineLength - 1)) + "…"
    }
}
