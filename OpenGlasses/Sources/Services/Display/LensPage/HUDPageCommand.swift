import Foundation

/// The page view's words (Plan KV §3). Parsed the same strict way as the answer card's paging
/// words (`HUDAnswerVoiceCommand`): whole short utterances only, leading filler tolerated, and the
/// caller consults it only while a page view is on the glasses. Anything longer — "zoom in on the
/// wiring" — is an ordinary request, so "next" or "up" inside a sentence is never taken.
enum HUDPageCommand: Equatable {
    case zoomIn
    case zoomOut
    case wholePage
    case move(LensPageViewport.Step)
    case corner(LensPageViewport.Corner)
    case nextPage
    /// Plan KV P1b: "next diagram" — the page's next drawing.
    case nextDiagram
    /// "The bottom one", "the second diagram" — the drawing a position names.
    case diagram(PageFigurePosition)
    case back
    case close
    /// Reading mode (§1): "next" — the next page of the passage's words. Taken only while reading
    /// mode is up.
    case next
    /// "Show the page" — from reading mode to the picture.
    case showPage
    /// "Read it" — from the picture to reading mode.
    case readIt

    static func parse(_ text: String) -> HUDPageCommand? {
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        if core.last == "please" { core.removeLast() }

        if let position = diagramPosition(core) { return .diagram(position) }

        switch core.joined(separator: " ") {
        case "zoom in", "closer", "zoom closer", "get closer":
            return .zoomIn
        case "zoom out", "further out", "farther out":
            return .zoomOut
        case "whole page", "the whole page", "show the whole page", "show whole page", "full page":
            return .wholePage
        case "up", "move up", "go up":
            return .move(.up)
        case "down", "move down", "go down":
            return .move(.down)
        case "left", "move left", "go left":
            return .move(.left)
        case "right", "move right", "go right":
            return .move(.right)
        case "top left", "the top left", "top left corner":
            return .corner(.topLeft)
        case "top right", "the top right", "top right corner":
            return .corner(.topRight)
        case "bottom left", "the bottom left", "bottom left corner":
            return .corner(.bottomLeft)
        case "bottom right", "the bottom right", "bottom right corner":
            return .corner(.bottomRight)
        case "next page", "the next page":
            return .nextPage
        case "next diagram", "the next diagram", "next drawing", "the next drawing", "next figure",
             "the next figure", "other diagram", "the other diagram", "another diagram":
            return .nextDiagram
        case "back", "go back", "previous":
            return .back
        case "next":
            return .next
        case "show the page", "show page", "show me the page", "the page", "page", "picture",
             "show the picture", "show me the picture":
            return .showPage
        case "read it", "read", "read that", "read the text", "show the text", "the text", "text":
            return .readIt
        case "close", "close the page", "close page", "close it", "close that":
            return .close
        default:
            return nil
        }
    }

    /// "the bottom one", "top diagram", "the second drawing", "the one at the bottom", "the one on
    /// the left". The noun (or "one") is required, so a bare "left" stays a move and "top left" a
    /// corner.
    private static func diagramPosition(_ words: [String]) -> PageFigurePosition? {
        var core = words
        if core.first == "the" { core.removeFirst() }
        let nouns: Set<String> = ["one", "diagram", "drawing", "figure"]
        if core.count == 2, nouns.contains(core[1]), let position = PageFigurePosition(word: core[0]) {
            return position
        }
        // "one at the bottom", "one on the left"
        if core.count == 4, core[0] == "one", ["at", "on"].contains(core[1]), core[2] == "the",
           let position = PageFigurePosition(word: core[3]) {
            return position
        }
        return nil
    }
}
