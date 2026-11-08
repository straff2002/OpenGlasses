#if DAT_MOCK_DISPLAY
import Foundation

/// One-tap openers for the simulated Display (Plan KV P4), so a developer can put each kind of
/// page on the lens and press its buttons by hand, with no model and no key. Each one stages a
/// page of the invented test manual exactly as the walkthrough does, with the words a request
/// would carry; the answer card is fed a fixed, invented reply. Nothing is sent, saved or asked.
@MainActor
enum SimulatedDisplayExample: String, CaseIterable, Identifiable {
    case diagram
    case wholePage
    case citedPassage
    case twoPassages
    case table
    case answerCard

    var id: String { rawValue }

    /// Developer-only labels; this file is never compiled into a build that ships.
    var title: String {
        switch self {
        case .diagram: return "Diagram on page 2"
        case .wholePage: return "Page 1 (whole page)"
        case .citedPassage: return "Cited passage on page 4"
        case .twoPassages: return "Two cited passages on page 4"
        case .table: return "Table on page 3"
        case .answerCard: return "Three-page answer card"
        }
    }

    var icon: String {
        switch self {
        case .diagram: return "point.3.connected.trianglepath.dotted"
        case .wholePage: return "doc"
        case .citedPassage, .twoPassages: return "text.alignleft"
        case .table: return "tablecells"
        case .answerCard: return "text.bubble"
        }
    }

    func open(on appState: AppState) {
        switch self {
        case .diagram:
            stage(SimulatedDisplayTestManual.staged(page: 2), words: "show me the diagram on page 2", appState)
        case .wholePage:
            stage(SimulatedDisplayTestManual.staged(page: 1, figure: "Figure 1"), words: "show me the page", appState)
        case .citedPassage:
            stage(SimulatedDisplayTestManual.staged(page: 4, cited: true), words: "how do I clear a latched fault", appState)
        case .twoPassages:
            stage(SimulatedDisplayTestManual.staged(page: 4, citedTwice: true), words: "how do I clear a latched fault", appState)
        case .table:
            stage(SimulatedDisplayTestManual.staged(page: 3, figure: "Table 1", pictured: true), words: "show me table 1", appState)
        case .answerCard:
            let card = appState.hudAnswerCard
            card.beginTurn(question: "how do I find a fault on the Q-7 board")
            card.finishTurn(reply: [
                "Start with the cover off and the board powered.",
                "Measure TP1 at the intake filter first; it should read between 0.4 and 0.9 volts.",
                "Then measure TP2 at the gain stage, which should sit between 2.1 and 2.6 volts.",
            ].joined(separator: " "))
            card.endTurn()
        }
    }

    private func stage(_ staged: FieldSessionService.StagedFigure, words: String, _ appState: AppState) {
        let lensPage = appState.lensPage
        let original = lensPage.requestWords
        lensPage.requestWords = { words }
        appState.presentOnLens([staged], opening: 0)
        lensPage.requestWords = original
    }
}
#endif
