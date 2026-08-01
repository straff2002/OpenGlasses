import Foundation

/// Plan AH — the renderer's typed output. The community reconstruction leaves the `…6402`
/// rendering payload ambiguous (text-command wire vs 1-bit framebuffer), so the renderer
/// targets this intermediate and only the packetizer cares which variant the device speaks.
/// v1 emits `.lines`; the bitmap variant exists so a framebuffer wire is a packetizer
/// change, not a renderer rewrite.
enum EvenFrame: Equatable {
    case lines([String])
    case bitmap(width: Int, height: Int, bits: [UInt8])

    /// The text wire's payload: lines joined by `\n`, UTF-8.
    var payloadBytes: [UInt8] {
        switch self {
        case .lines(let lines):
            return Array(lines.joined(separator: "\n").utf8)
        case .bitmap(_, _, let bits):
            return bits
        }
    }
}

/// Pure `HUDScreen`/content → `EvenFrame` mapping for the monochrome 576×288 panel.
/// Mono mappings (decided, tested): emphasis → plain / two-space indent / "· " prefix;
/// buttons → numbered entries (the number grammar joins the voice-selection story); each
/// of the ten semantic icons → a text glyph. Char budget is a device-pending starting
/// point — 576 px at a ~12 px advance ≈ 48 cells; 44 leaves margin.
enum EvenScreenRenderer {

    static let charBudget = 44
    static let maxLines = 8

    // MARK: - Content (ambient / notification / navigation)

    static func render(title: String?, body: String, icon: HUDIcon) -> EvenFrame {
        var lines: [String] = []
        let glyph = iconGlyph(icon)
        if let title, !title.isEmpty {
            lines.append(prefixed(glyph, HUDTextShaper.condense(title, max: charBudget)))
            lines.append(contentsOf: wrap(body, width: charBudget, maxLines: maxLines - 1))
        } else {
            let wrapped = wrap(body, width: charBudget, maxLines: maxLines)
            if let first = wrapped.first {
                lines.append(prefixed(glyph, first))
                lines.append(contentsOf: wrapped.dropFirst())
            } else if let glyph {
                lines.append(glyph)
            }
        }
        return .lines(Array(lines.prefix(maxLines)))
    }

    // MARK: - Interactive screens

    static func render(screen: HUDScreen) -> EvenFrame {
        var lines: [String] = []
        if let title = screen.title, !title.isEmpty {
            lines.append(HUDTextShaper.condense(title, max: charBudget))
        }
        for line in screen.lines {
            let condensed = HUDTextShaper.condense(line.text, max: charBudget - 4)
            let glyphed = prefixed(iconGlyph(line.icon), condensed)
            switch line.emphasis {
            case .primary: lines.append(glyphed)
            case .secondary: lines.append("  " + glyphed)
            case .meta: lines.append("· " + glyphed)
            }
        }
        for (index, item) in screen.items.enumerated() {
            let label = HUDTextShaper.condense(item.label, max: charBudget - 4)
            lines.append("\(index + 1). \(label)")
        }
        return .lines(Array(lines.prefix(maxLines)))
    }

    static func clearFrame() -> EvenFrame { .lines([]) }

    /// All ten semantic icons, enumerated → a mono glyph (or nothing).
    static func iconGlyph(_ icon: HUDIcon) -> String? {
        switch icon {
        case .none: return nil
        case .info: return "(i)"
        case .success: return "[✓]"
        case .warning: return "[!]"
        case .error: return "[✕]"
        case .navigation: return "→"
        case .hazard: return "[!]"
        case .calendar: return "[▤]"
        case .location: return "[⌂]"
        case .reminder: return "[•]"
        case .message: return "[✉]"
        }
    }

    // MARK: - Helpers

    /// Head-biased word wrap (the caption formatter's wrap is tail-biased — a live
    /// caption keeps the newest text, a HUD card keeps the start of the message).
    static func wrap(_ text: String, width: Int, maxLines: Int) -> [String] {
        let condensed = HUDTextShaper.condense(text, max: width * maxLines)
        guard !condensed.isEmpty, width > 0, maxLines > 0 else { return [] }
        var lines: [String] = []
        var current = ""
        for word in condensed.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= width {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                var chunk = String(word)
                while chunk.count > width {
                    lines.append(String(chunk.prefix(width)))
                    chunk = String(chunk.dropFirst(width))
                }
                current = chunk
            }
            if lines.count >= maxLines { break }
        }
        if !current.isEmpty, lines.count < maxLines { lines.append(current) }
        return Array(lines.prefix(maxLines))
    }

    private static func prefixed(_ glyph: String?, _ text: String) -> String {
        guard let glyph else { return text }
        return "\(glyph) \(text)"
    }
}
