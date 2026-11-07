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
    case back
    case close

    static func parse(_ text: String) -> HUDPageCommand? {
        let stripped = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
        let words = stripped.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let filler: Set<String> = ["ok", "okay", "hey", "please", "uh", "um", "yeah", "yep", "now"]
        var core = Array(words.drop(while: { filler.contains($0) }))
        if core.last == "please" { core.removeLast() }

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
        case "back", "go back":
            return .back
        case "close", "close the page", "close page", "close it", "close that":
            return .close
        default:
            return nil
        }
    }
}
