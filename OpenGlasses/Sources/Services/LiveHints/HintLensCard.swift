import Foundation

/// The two lens pages of one hint (Plan MO §6), built as answer-card screens so the lens shows them
/// through `GlassesDisplayService.presentAnswerCard(_:wearerLed: false)` and pages them with
/// `turnAnswerCard(to:issuedAgainst:onSelect:)`, as `HUDAnswerCard` does.
///
/// | Page | Lines | Buttons |
/// |---|---|---|
/// | 1 | the question in a few words, dimmed (meta); "Suggestion" in Medical Compliance mode; the hint | Next › · Close |
/// | 2 | the full answer; the source (the document, or "General knowledge"), dimmed | ‹ Back · Close |
///
/// A hint with nothing more to say than its line (a key point, a passage card whose full text is the
/// line) is one page, with Close only. Every page carries the card's pages in `HUDScreen.pageSet`, as
/// an answer card's do.
///
/// Pure: actions are reported through `onAction`.
enum HintLensCardBuilder {

    enum Action: Equatable {
        case next
        case back
        case close
    }

    /// Stable item ids, so a band press routes back by id.
    enum ItemID {
        static let next = "mo.hint.next"
        static let back = "mo.hint.back"
        static let close = "mo.hint.close"
    }

    /// Hint card numbers start here, far above the answer card's own count, so a hint and an answer
    /// never share a `HUDPageSet.card` (the display compares it to tell a dismissed card from a new
    /// one).
    static let cardSerialBase = 1_000_000

    static func pages(for hint: LiveHint, geometry: TeleprompterPaginator.Geometry, suggestion: Bool,
                      onAction: @escaping (Action) -> Void) -> [HUDScreen] {
        let width = max(8, geometry.maxChars)
        var first: [HUDLine] = []
        if let question = hint.question {
            let glance = HintQuestionGlance.glance(question)
            if !glance.isEmpty { first.append(HUDLine(oneLine(glance, width: width), emphasis: .meta)) }
        } else if let keyword = hint.keyword {
            first.append(HUDLine(oneLine(keyword, width: width), emphasis: .meta))
        }
        if suggestion {
            first.append(HUDLine(String(localized: "Suggestion",
                                        comment: "Live hints card, Medical Compliance mode: the line under it is a suggestion, not advice."),
                                 emphasis: .secondary))
        }
        first += wrapped(hint.line, width: width, emphasis: .primary)

        var second: [HUDLine] = []
        let full = hint.full.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty, full != hint.line { second += wrapped(full, width: width, emphasis: .primary) }
        let hasSecondPage = !second.isEmpty
        if let label = hint.sourceLabel {
            let sourceLine = HUDLine(oneLine(label, width: width), emphasis: .meta)
            if hasSecondPage { second.append(sourceLine) } else { first.append(sourceLine) }
        }

        let close = HUDItem(id: ItemID.close, label: String(localized: "Close"), style: .outline) { onAction(.close) }
        var firstItems: [HUDItem] = []
        if hasSecondPage {
            firstItems.append(HUDItem(id: ItemID.next, label: String(localized: "Next ›"), style: .primary) { onAction(.next) })
        }
        firstItems.append(close)
        var screens = [HUDScreen(title: nil, lines: first, items: firstItems)]
        if hasSecondPage {
            let back = HUDItem(id: ItemID.back, label: String(localized: "‹ Back"), style: .secondary) { onAction(.back) }
            screens.append(HUDScreen(title: nil, lines: second, items: [back, close]))
        }
        let card = cardSerialBase + hint.id
        return screens.indices.map { index in
            var screen = screens[index]
            screen.pageSet = HUDPageSet(pages: screens, index: index, card: card)
            return screen
        }
    }

    /// One display line: `condense` adds "…" after its cut, so cut one short.
    private static func oneLine(_ text: String, width: Int) -> String {
        let line = HUDTextShaper.condense(text, max: Int.max)
        guard line.count > width else { return line }
        return HUDTextShaper.condense(line, max: width - 1)
    }

    private static func wrapped(_ text: String, width: Int, emphasis: HUDEmphasis) -> [HUDLine] {
        HintText.collapsingWhitespace(text).isEmpty ? [] :
            TeleprompterPaginator.wrap(HintText.collapsingWhitespace(text), maxChars: width)
                .map { HUDLine($0, emphasis: emphasis) }
    }
}
