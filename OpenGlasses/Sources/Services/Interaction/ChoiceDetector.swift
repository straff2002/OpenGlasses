import Foundation

/// One selectable option detected inside an assistant reply.
struct DetectedChoice: Equatable {
    /// Short text for the HUD button (condensed to fit in-lens).
    let label: String
    /// What selecting the button feeds back into the conversation as the user's turn.
    let spokenForm: String
}

/// Detects explicit multiple-choice enumerations in assistant replies so the HUD can
/// render them as band-selectable buttons (Plan CG P1).
///
/// Conservative by contract: a false button is worse than a missed one, so only
/// unambiguous choice shapes match —
///  1. lettered lists ("A) …" / "B. …") of 2–5 short items,
///  2. numbered or dashed lists, but only with a choice cue ("which", "pick", a nearby
///     question mark) in the surrounding text — otherwise they're instructions/steps,
///  3. a trailing "X, Y, or Z?" question with an interrogative lead-in.
/// Code fences never match.
enum ChoiceDetector {
    static let maxChoices = 5
    static let minChoices = 2
    /// Enumerated items longer than this read as prose (steps, explanations), not options.
    static let maxItemLength = 80
    /// How far around a numbered/dashed list to look for a choice cue.
    static let cueWindow = 200

    static func detect(in reply: String) -> [DetectedChoice] {
        let text = strippingCodeFences(from: reply)

        if let listChoices = detectListEnumeration(in: text) { return listChoices }
        if let inline = detectInlineLettered(in: text) { return inline }
        if let tail = detectTailQuestion(in: text) { return tail }
        return []
    }

    // MARK: - Shapes

    /// Kind of list marker a line carries.
    private enum ListKind { case letter, number, dash }

    /// Lines like "A) Riverside walk" / "1. Museum loop" / "- Coffee first".
    private static func detectListEnumeration(in text: String) -> [DetectedChoice]? {
        struct Marker { let kind: ListKind; let ordinal: Int; let body: String; let lineStart: Int }

        let lines = text.components(separatedBy: "\n")
        var markers: [Marker] = []
        var offset = 0
        for line in lines {
            defer { offset += line.count + 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let m = parseMarkedLine(trimmed) {
                markers.append(Marker(kind: m.0, ordinal: m.1, body: m.2, lineStart: offset))
            } else {
                // A non-marker line breaks a run; keep only the longest complete run.
                markers.append(Marker(kind: .dash, ordinal: -1, body: "", lineStart: offset))
            }
        }

        // Find the longest run of same-kind, sequentially-ordinal markers.
        var best: [Marker] = []
        var run: [Marker] = []
        for m in markers {
            if m.ordinal == -1 { if run.count > best.count { best = run }; run = []; continue }
            if let last = run.last, last.kind == m.kind,
               (m.kind == .dash || m.ordinal == last.ordinal + 1) {
                run.append(m)
            } else {
                if run.count > best.count { best = run }
                run = (m.kind == .dash || m.ordinal == 1) ? [m] : []
            }
        }
        if run.count > best.count { best = run }

        guard best.count >= minChoices, best.count <= maxChoices,
              best.allSatisfy({ !$0.body.isEmpty && $0.body.count <= maxItemLength })
        else { return nil }

        // Lettered lists are choice-shaped on their own; numbered/dashed lists are
        // routinely steps ("1. Preheat the oven") and need a cue nearby.
        if best[0].kind != .letter {
            guard hasChoiceCue(in: text, around: best[0].lineStart) else { return nil }
        }
        return best.map { choice(from: $0.body) }
    }

    /// "A) Sydney, B) Melbourne, or C) Perth." inside one sentence.
    private static func detectInlineLettered(in text: String) -> [DetectedChoice]? {
        // Lookbehind keeps word-final letters ("…sofa. Then…") from reading as markers.
        let pattern = #"(?<![A-Za-z0-9])([A-Ha-h])[\)\.]\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        // Each option's body runs from its marker to the next marker or the first
        // punctuation, whichever comes first — the conservative read of where an
        // inline option ends.
        struct Inline { let letter: Int; let body: String }
        var options: [Inline] = []
        for (i, m) in matches.enumerated() {
            let letter = Int(ns.substring(with: m.range(at: 1)).uppercased().unicodeScalars.first!.value) - 65
            let bodyStart = m.range.location + m.range.length
            let hardEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            var body = ns.substring(with: NSRange(location: bodyStart, length: hardEnd - bodyStart))
            if let stop = body.rangeOfCharacter(from: CharacterSet(charactersIn: ",;.?!\n")) {
                body = String(body[..<stop.lowerBound])
            }
            // Trim connector residue between options ("Melbourne or ").
            body = body.trimmingCharacters(in: .whitespaces)
            for connector in [" or", " and"] where body.lowercased().hasSuffix(connector) {
                body = String(body.dropLast(connector.count)).trimmingCharacters(in: .whitespaces)
            }
            options.append(Inline(letter: letter, body: body))
        }

        var run: [Inline] = []
        var best: [Inline] = []
        for option in options {
            if let last = run.last, option.letter == last.letter + 1 {
                run.append(option)
            } else {
                if run.count > best.count { best = run }
                run = option.letter == 0 ? [option] : []
            }
        }
        if run.count > best.count { best = run }

        guard best.count >= minChoices, best.count <= maxChoices,
              best.allSatisfy({ !$0.body.isEmpty && $0.body.count <= 60 })
        else { return nil }
        return best.map { choice(from: $0.body) }
    }

    /// Final sentence of the form "Would you like X, Y, or Z?".
    private static func detectTailQuestion(in text: String) -> [DetectedChoice]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return nil }
        // Last sentence only.
        let sentence = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .dropLast()  // trailing empty component after the final "?"
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let leads = ["would you like", "would you prefer", "do you want", "should i",
                     "shall i", "which", "want me to"]
        let lower = sentence.lowercased()
        guard leads.contains(where: { lower.hasPrefix($0) || lower.contains(", \($0)") }),
              lower.contains(" or ") else { return nil }

        // Options are what follows the lead-in verb phrase, split on commas/" or ".
        guard let colonless = sentence.range(of: #"(?i)(like|prefer|want|should i|shall i|which( one)?( do you prefer)?[:,]?|want me to)\s+"#,
                                             options: .regularExpression) else { return nil }
        let tail = String(sentence[colonless.upperBound...])
        let parts = tail
            .replacingOccurrences(of: ", or ", with: "|")
            .replacingOccurrences(of: " or ", with: "|")
            .replacingOccurrences(of: ", ", with: "|")
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard parts.count >= minChoices, parts.count <= 4,
              parts.allSatisfy({ $0.count <= 40 && !$0.contains("?") })
        else { return nil }
        return parts.map { choice(from: $0) }
    }

    // MARK: - Helpers

    private static func parseMarkedLine(_ line: String) -> (ListKind, Int, String)? {
        // Returns kind, ordinal (A=1, "1."=1, dash=0), body.
        if let m = line.range(of: #"^([A-Ha-h])[\)\.]\s+"#, options: .regularExpression) {
            let letter = line[line.startIndex].uppercased().unicodeScalars.first!.value
            return (.letter, Int(letter) - 64, String(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^(\d{1,2})[\)\.]\s+"#, options: .regularExpression) {
            let digits = line.prefix(while: { $0.isNumber })
            return (.number, Int(digits) ?? 0, String(line[m.upperBound...]))
        }
        if let m = line.range(of: #"^[-•]\s+"#, options: .regularExpression) {
            return (.dash, 0, String(line[m.upperBound...]))
        }
        return nil
    }

    private static func hasChoiceCue(in text: String, around index: Int) -> Bool {
        let lower = text.lowercased()
        let start = lower.index(lower.startIndex, offsetBy: max(0, index - cueWindow))
        let end = lower.index(lower.startIndex, offsetBy: min(lower.count, index + cueWindow))
        let window = lower[start..<end]
        let cues = ["which", "choose", "pick", "prefer", "option", "would you like", "?"]
        return cues.contains { window.contains($0) }
    }

    private static func strippingCodeFences(from text: String) -> String {
        guard text.contains("```") else { return text }
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if !inFence { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    private static func choice(from body: String) -> DetectedChoice {
        let spoken = body.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:!"))
        return DetectedChoice(label: HUDTextShaper.condense(spoken, max: HUDTextShaper.maxTitleLength),
                              spokenForm: spoken)
    }
}
