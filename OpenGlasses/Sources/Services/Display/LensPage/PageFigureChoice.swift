import CoreGraphics
import Foundation

/// "The top diagram", "the one at the bottom", "the second drawing" (Plan KV P1b): a drawing
/// named by where it sits, against the drawings in reading order.
enum PageFigurePosition: String, Equatable, Sendable, CaseIterable {
    case top, bottom, left, right, first, second, third, last

    /// The word, or its plain synonym ("upper", "lower").
    init?(word: String) {
        switch word {
        case "top", "upper", "uppermost", "topmost": self = .top
        case "bottom", "lower", "lowest", "bottommost": self = .bottom
        case "left", "leftmost", "lefthand": self = .left
        case "right", "rightmost", "righthand": self = .right
        case "first", "1st": self = .first
        case "second", "2nd": self = .second
        case "third", "3rd": self = .third
        case "last": self = .last
        default: return nil
        }
    }
}

/// What a request said about the drawing it wants, read from the technician's words for the turn
/// and the staged page (Plan KV P1b). Plain values, so it crosses into the layout task.
///
/// **Whether a drawing was asked for** (`asksForDrawing`) decides whether the drawing goes ahead
/// of a cited passage in the focus order (§1). The code does not carry which tool staged a page —
/// `manual_figure`, `show_source` and an answer's own evidence all reach the lens as a
/// `StagedFigure` through the same `presentOnLens` — so the request is read from what it does
/// carry:
/// - the turn's words (`TechnicianWords.current()`, read by `LensPageSession.stage`) name a
///   drawing: one of `drawingWords` ("show me the wiring diagram", "show me figure 12" — which is
///   how a `manual_figure` figure request is said), or the staged caption's number with the
///   caption a figure's ("show me 12" for "Figure 12");
/// - with no words for the turn (a citation chip tapped, a live-mode turn), the staged page has a
///   figure's caption ("Figure 12", "Fig. 3") and the technician asked for it (`.requested`).
/// A table's caption is not a drawing, so "show me table 16" keeps the table's marks first.
///
/// **Whether the drawing is a focus at all** (`drawingFocus`, §1): only when a drawing was asked
/// for, or when the app put the page up by itself (`.automatic`) and its caption is a figure's.
/// A request for the page ("show me page 7") with nothing cited opens the whole page; the page's
/// drawings are still found, and **Next diagram ›** jumps to one.
struct PageFigureAsk: Equatable, Sendable {
    /// Where the drawing stands in the focus order (§1).
    enum DrawingFocus: String, Equatable, Sendable {
        /// Not a focus: the view opens on the cited passages, the table's area or the whole page.
        case none
        /// After the cited passages and the table's area (a figure page the app put up).
        case afterMarks
        /// Ahead of everything (a drawing was asked for).
        case first
    }

    /// The figure number the request named ("12" for "figure 12"), else the staged caption's.
    var captionNumber: String?
    /// The request's content words, lower-cased: what is matched against a drawing's labels.
    var words: [String]
    var position: PageFigurePosition?
    var asksForDrawing: Bool
    /// The app put the page up by itself (`.automatic`) for its figure: the staged caption is a
    /// figure's.
    var isAutomaticFigure: Bool = false

    static let none = PageFigureAsk(captionNumber: nil, words: [], position: nil, asksForDrawing: false)

    var drawingFocus: DrawingFocus {
        if asksForDrawing { return .first }
        return isAutomaticFigure ? .afterMarks : .none
    }

    /// The nouns that ask for a drawing.
    static let drawingWords: Set<String> = [
        "diagram", "diagrams", "drawing", "drawings", "figure", "figures", "fig", "schematic", "schematics",
        "wiring", "picture", "pictures", "illustration", "illustrations",
    ]

    /// Words that carry no content: `ManualDocumentChoice`'s filler ("the", "of", "and", "page",
    /// "manual's") and its generic book words, with the words a request to be shown something is
    /// made of. Anything under three letters is dropped too, as `ManualDocumentChoice.matches` does.
    static let filler: Set<String> = [
        "the", "of", "and", "page", "manual's", "manual", "manuals", "guide", "book", "for",
        "show", "see", "look", "let", "can", "you", "could", "would", "will", "please", "open", "display",
        "put", "bring", "give", "get", "want", "need", "glasses", "lens", "one", "ones", "with", "this",
        "that", "these", "those", "what", "where", "which", "are", "its", "from", "there", "here", "into",
        "onto", "about", "again", "just", "then", "now", "okay", "hey", "page's", "side", "corner",
    ]

    static func parse(said: String?, caption: String?, origin: PageOrigin) -> PageFigureAsk {
        let stagedNumber = figureNumber(inCaption: caption)
        let automaticFigure = stagedNumber != nil && origin == .automatic
        guard let said, !said.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PageFigureAsk(captionNumber: stagedNumber, words: [], position: nil,
                                 asksForDrawing: stagedNumber != nil && origin == .requested,
                                 isAutomaticFigure: automaticFigure)
        }
        let tokens = tokens(said)
        let named = figureNumber(inRequest: tokens)
        let position = tokens.lazy.compactMap(PageFigurePosition.init(word:)).first
        let content = tokens.filter { word in
            word.count >= 3 && !filler.contains(word) && !drawingWords.contains(word)
                && PageFigurePosition(word: word) == nil && !word.allSatisfy(\.isNumber)
        }
        // The staged figure's number said on its own ("show me 12"), not as a page ("page 12").
        let saysStagedNumber = stagedNumber.map { number in
            tokens.indices.contains { tokens[$0] == number && ($0 == 0 || !["page", "p", "pg"].contains(tokens[$0 - 1])) }
        } ?? false
        let namesDrawing = tokens.contains(where: drawingWords.contains) || saysStagedNumber
        var seen = Set<String>()
        return PageFigureAsk(captionNumber: named ?? stagedNumber,
                             words: content.filter { seen.insert($0).inserted },
                             position: position, asksForDrawing: namesDrawing,
                             isAutomaticFigure: automaticFigure)
    }

    /// What tells two asks apart, for the layout cache.
    var key: String {
        [captionNumber ?? "", words.joined(separator: " "), position?.rawValue ?? "", drawingFocus.rawValue]
            .joined(separator: "\u{1F}")
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// "Figure 12", "Fig. 12a" → "12"; a table's caption, or none, → nil.
    static func figureNumber(inCaption caption: String?) -> String? {
        guard let caption else { return nil }
        let tokens = tokens(caption)
        guard let first = tokens.first, first == "figure" || first == "fig", tokens.count > 1,
              tokens[1].first?.isNumber == true else { return nil }
        return tokens[1]
    }

    /// "figure 12" / "fig 12" in a request → "12".
    static func figureNumber(inRequest tokens: [String]) -> String? {
        for (index, word) in tokens.enumerated() where word == "figure" || word == "fig" {
            if index + 1 < tokens.count, tokens[index + 1].first?.isNumber == true { return tokens[index + 1] }
        }
        return nil
    }
}

/// Which of a page's drawings the view opens on (Plan KV P1b). Pure. Each step is used only when
/// it decides:
/// 1. **A named caption** found on the page: the drawing nearest it, above or below (captions sit
///    on either side). Decides when one drawing is nearer than the rest by `captionMarginPoints`.
/// 2. **The request's words**, matched whole-word against each drawing's labels and heading, the
///    way `ManualDocumentChoice` matches titles (a plural matches its singular): one drawing with
///    more of the words than any other.
/// 3. **A position word**, against the drawings in reading order: "top" is the drawing wholly above
///    the middle of every other, "left" wholly left of them; "second" is the second in reading
///    order.
/// 4. **Otherwise the largest** (the first in reading order on a tie).
struct PageFigureChoice: Equatable {
    enum Reason: String, Equatable {
        case caption, words, position, largest, only
    }

    /// The page's drawings, in reading order.
    let drawings: [PageDrawing]
    /// The one the view opens on; nil when the page has none.
    let index: Int?
    let reason: Reason?

    static let captionMarginPoints: CGFloat = 4

    static func choose(_ drawings: [PageDrawing], ask: PageFigureAsk, captionRects: [CGRect] = []) -> PageFigureChoice {
        guard !drawings.isEmpty else { return PageFigureChoice(drawings: [], index: nil, reason: nil) }
        guard drawings.count > 1 else { return PageFigureChoice(drawings: drawings, index: 0, reason: .only) }
        if let index = nearestToCaption(drawings, captionRects) {
            return PageFigureChoice(drawings: drawings, index: index, reason: .caption)
        }
        if let index = bestByWords(drawings, ask.words) {
            return PageFigureChoice(drawings: drawings, index: index, reason: .words)
        }
        if let position = ask.position, let index = index(for: position, in: drawings) {
            return PageFigureChoice(drawings: drawings, index: index, reason: .position)
        }
        return PageFigureChoice(drawings: drawings, index: largest(drawings), reason: .largest)
    }

    /// The chosen drawing's rectangle.
    var rect: CGRect? { index.map { drawings[$0].rect } }

    // MARK: Steps

    static func nearestToCaption(_ drawings: [PageDrawing], _ captions: [CGRect]) -> Int? {
        let found = captions.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !found.isEmpty else { return nil }
        let distances = drawings.map { drawing in
            found.map { distance(drawing.rect, $0) }.min() ?? .greatestFiniteMagnitude
        }
        let sorted = distances.sorted()
        guard let best = sorted.first, sorted.count < 2 || sorted[1] - best > captionMarginPoints else { return nil }
        return distances.firstIndex(of: best)
    }

    static func bestByWords(_ drawings: [PageDrawing], _ words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }
        let scores = drawings.map { drawing -> Int in
            var vocabulary = Set<String>()
            for line in drawing.labels + [drawing.heading].compactMap({ $0 }) {
                for token in PageFigureAsk.tokens(line.text) {
                    vocabulary.insert(token)
                    vocabulary.insert(singular(token))
                }
            }
            return words.filter { vocabulary.contains($0) || vocabulary.contains(singular($0)) }.count
        }
        guard let best = scores.max(), best > 0, scores.filter({ $0 == best }).count == 1 else { return nil }
        return scores.firstIndex(of: best)
    }

    /// The drawing a position names, when it names exactly one. `drawings` are in reading order.
    static func index(for position: PageFigurePosition, in drawings: [PageDrawing]) -> Int? {
        guard !drawings.isEmpty else { return nil }
        let rects = drawings.map(\.rect)
        func extreme(_ better: (CGRect, CGRect) -> Bool, clear: (CGRect, CGRect) -> Bool) -> Int? {
            guard let index = rects.indices.min(by: { better(rects[$0], rects[$1]) }) else { return nil }
            let others = rects.indices.filter { $0 != index }
            return others.allSatisfy({ clear(rects[index], rects[$0]) }) ? index : nil
        }
        switch position {
        case .top: return extreme({ $0.midY < $1.midY }, clear: { $0.maxY <= $1.midY })
        case .bottom: return extreme({ $0.midY > $1.midY }, clear: { $0.minY >= $1.midY })
        case .left: return extreme({ $0.midX < $1.midX }, clear: { $0.maxX <= $1.midX })
        case .right: return extreme({ $0.midX > $1.midX }, clear: { $0.minX >= $1.midX })
        case .first: return 0
        case .second: return drawings.count > 1 ? 1 : nil
        case .third: return drawings.count > 2 ? 2 : nil
        case .last: return drawings.count - 1
        }
    }

    static func largest(_ drawings: [PageDrawing]) -> Int {
        var best = 0
        for index in drawings.indices.dropFirst() where drawings[index].area > drawings[best].area { best = index }
        return best
    }

    /// The gap between two rectangles (zero when they touch or overlap).
    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }

    // MARK: The caption on the page

    /// Where the page's text names figure `number`: each occurrence as a text range. Captions
    /// start a line ("Figure 12. Blower wiring"), and a mention in a paragraph ("see Figure 12")
    /// does not, so occurrences that start a line are preferred when there are any.
    static func captionRanges(number: String, in text: String) -> [NSRange] {
        let escaped = NSRegularExpression.escapedPattern(for: number)
        guard let regex = try? NSRegularExpression(pattern: "\\bfig(?:ure)?\\.?\\s*\(escaped)(?![0-9A-Za-z])",
                                                   options: [.caseInsensitive]) else { return [] }
        let string = text as NSString
        let all = regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map(\.range)
        let starting = all.filter { range in
            var index = range.location - 1
            while index >= 0 {
                let unit = string.character(at: index)
                if unit == 0x0A || unit == 0x0D { return true }
                guard unit == 0x20 || unit == 0x09 else { return false }
                index -= 1
            }
            return true
        }
        return starting.isEmpty ? all : starting
    }

    /// Each occurrence's lines united, through the page's text geometry.
    static func captionRects(number: String, text: String, geometry: PageTextGeometry) -> [CGRect] {
        captionRanges(number: number, in: text).compactMap { range in
            let lines = geometry.lineRects(for: range)
            guard let first = lines.first else { return nil }
            return lines.dropFirst().reduce(first) { $0.union($1) }
        }
    }
}
