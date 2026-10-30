import Foundation

/// What kind of thing a technician said, as far as putting a manual page in front of them goes
/// (Plan GB P1).
///
/// Every Field Assist turn is searched against the manuals, and before this every turn whose
/// evidence named a drawing *or any captioned passage* put that page on the phone. In the field
/// test that meant a venting table opening after "0.28", and a CO₂ table after "135 not 140" —
/// readings and a correction, which ask for no page at all. The kind of turn is the first thing
/// that decides whether a page may open by itself.
///
/// Deterministic and deliberately plain: a handful of phrase rules over the words, no model. A
/// misclassified turn costs at most a page not opening, which "show me the drawing" fixes.
enum ManualTurnKind: String, Equatable {
    /// Running the job — opening, closing, correcting its number (`ManualTurnScope`).
    case jobBookkeeping
    /// Correcting something said before: "135 not 140", "sorry, I meant 0.35".
    case correction
    /// Asking for a page: "show me the wiring diagram", "pull up table 8".
    case showMe
    /// A value read off the machine: "0.28", "supply air is 140".
    case reading
    /// A question about the machine.
    case question
    /// Anything else — a remark, a description of what they did.
    case statement
}

enum ManualTurnClassifier {

    static func classify(_ turn: String) -> ManualTurnKind {
        let words = self.words(turn)
        guard !words.isEmpty else { return .statement }
        if ManualTurnScope.isJobManagement(turn) { return .jobBookkeeping }
        if isCorrection(words) { return .correction }
        if isShowMe(words) { return .showMe }
        let asks = isQuestion(turn, words: words)
        if !asks, isReading(words) { return .reading }
        return asks ? .question : .statement
    }

    /// Lowercased words with decimals kept whole ("0.28" is one word, not "0" and "28") and the
    /// apostrophes dropped so "what's" and "whats" compare alike.
    static func words(_ turn: String) -> [String] {
        let lowered = turn.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return CodeTokenizer.words(in: lowered)
    }

    // MARK: - Rules

    private static func isCorrection(_ words: [String]) -> Bool {
        let text = " " + words.joined(separator: " ") + " "
        if correctionPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        // "135 not 140", "0.35 not 0.28": a value, then "not", then a value.
        for index in words.indices.dropFirst().dropLast() where words[index] == "not" {
            if CodeTokenizer.isNumber(words[index - 1]) && CodeTokenizer.isNumber(words[index + 1]) {
                return true
            }
        }
        return false
    }

    private static func isShowMe(_ words: [String]) -> Bool {
        let text = " " + words.joined(separator: " ") + " "
        if showPhrases.contains(where: { text.contains(" \($0) ") }) { return true }
        // "open page 30", "go to figure 58": a verb, then the thing a page is.
        guard words.contains(where: pageVerbs.contains) else { return false }
        return words.contains(where: pageNouns.contains)
    }

    private static func isQuestion(_ turn: String, words: [String]) -> Bool {
        if turn.contains("?") { return true }
        if let first = words.first, questionOpeners.contains(first) { return true }
        let text = " " + words.joined(separator: " ") + " "
        return askingPhrases.contains { text.contains(" \($0) ") }
    }

    /// A short remark carrying a plain number, which is how a reading is said aloud.
    private static func isReading(_ words: [String]) -> Bool {
        words.count <= maximumReadingWords && words.contains(where: CodeTokenizer.isNumber)
    }

    // MARK: - Vocabulary

    private static let maximumReadingWords = 10

    private static let correctionPhrases: [String] = [
        "correction", "i meant", "i mean", "sorry", "scratch that", "make that", "correct that",
        "change that", "that should be", "it should be", "should have been", "not what i said",
    ]

    private static let showPhrases: [String] = [
        "show me", "show the", "pull up", "bring up", "let me see", "can i see", "put up",
    ]

    private static let pageVerbs: Set<String> = ["show", "open", "display", "go", "turn", "see"]

    private static let pageNouns: Set<String> = [
        "page", "figure", "fig", "diagram", "drawing", "table", "chart", "schematic", "wiring",
        "manual",
    ]

    private static let questionOpeners: Set<String> = [
        "what", "whats", "why", "how", "hows", "where", "wheres", "which", "when", "who", "is",
        "are", "does", "do", "did", "can", "could", "should", "will", "would",
    ]

    private static let askingPhrases: [String] = ["tell me", "explain", "i need to know"]
}

/// Whether a turn's manual page may open on the phone by itself (Plan GB P1).
///
/// Three answers, because a page the technician did not ask to see can still be useful to the
/// model: a drawing reaches the model as a picture on any turn that asks about the machine (EK §4),
/// whether or not it is put on the phone.
///
/// **This decides presentation, never ranking.** The retriever's order, query variants and
/// passage budget are exactly as they were (EJ/FQ); the passages still go to the model on every
/// turn. What changes is which pages open unasked.
enum FigureAutoOpenPolicy {

    /// What the passage that would open is.
    enum PassageKind: String, Equatable {
        /// A drawing — a wiring diagram, a layout.
        case diagram
        /// A captioned passage that is not a drawing: a table, mostly.
        case captioned
        /// One row of an extracted table, written by the app (Plan JJ P0). Never a drawing, and
        /// never opens its page unasked: it is attached to the model at most.
        case tableRow

        /// The kind a retrieved chunk presents as. A prose passage reaches here only when it
        /// carries a caption (`FieldSessionService.bestFigure`).
        init(_ kind: DocumentChunker.Kind) {
            switch kind {
            case .diagram: self = .diagram
            case .prose: self = .captioned
            case .tableRow: self = .tableRow
            }
        }
    }

    enum Decision: Equatable {
        /// Put it on the phone and hand it to the model.
        case present(reason: Reason)
        /// Hand it to the model as the turn's picture, but do not open it on the phone.
        case attachToModelOnly(reason: Reason)
        /// Neither. The previous figure is cleared (EK P2).
        case none(reason: Reason)

        var reason: Reason {
            switch self {
            case .present(let reason), .attachToModelOnly(let reason), .none(let reason): return reason
            }
        }

        var presentsOnPhone: Bool {
            if case .present = self { return true }
            return false
        }

        var stagesFigure: Bool {
            if case .none = self { return false }
            return true
        }
    }

    /// Why — logged with the presentation, so the diagnostics can say which turn put which page on
    /// screen and why (the field test could not).
    enum Reason: String, Equatable {
        case askedForPage = "asked_for_page"
        case diagramForQuestion = "diagram_for_question"
        case tableNotAskedFor = "table_not_asked_for"
        case notAQuestion = "not_a_question"
        case numbersOnly = "numbers_only"
        case jobBookkeeping = "job_bookkeeping"
        case correction = "correction"
        case reading = "reading"
        case nothingFound = "nothing_found"
        case otherPageNamed = "other_page_named"
        /// The turn named a table or figure, and this page carries another label (Plan KD P3).
        case otherLabelNamed = "other_label_named"
        /// A table handed to the model whose label the turn named or `table_lookup` read.
        case labelAsked = "label_asked"
        /// A table that would have gone to the model alone, its label neither named nor looked up.
        case labelNotAsked = "label_not_asked"
    }

    /// Decide for one turn. `tokenHits` are the exact tokens that matched the passage — a hit made
    /// only of numbers ("135", "0.28") is a coincidence of a spoken value and a table cell, not a
    /// reference to the page. `namedPages` are the pages the turn named (`PageReference`) and
    /// `passagePage` the page the passage is on.
    static func decide(turnKind: ManualTurnKind, passageKind: PassageKind?,
                       tokenHits: [String], namedPages: Set<Int> = [],
                       passagePage: Int? = nil) -> Decision {
        switch turnKind {
        case .jobBookkeeping: return .none(reason: .jobBookkeeping)
        case .correction: return .none(reason: .correction)
        case .reading: return .none(reason: .reading)
        case .showMe, .question, .statement: break
        }
        guard let passageKind else { return .none(reason: .nothingFound) }
        // A turn that names a page has said which page it wants. Any other page is the wrong one,
        // however it was found: "why did you open installation, I said page 34 of the service
        // manual" asked for a page, and the automatic path opened the vent table its search had
        // found instead (field report, build 497). The named page is `manual_figure`'s to open;
        // the passages still go to the model.
        if !namedPages.isEmpty, !(passagePage.map(namedPages.contains) ?? false) {
            return .none(reason: .otherPageNamed)
        }
        // Asked for: whatever it is, it opens.
        if turnKind == .showMe { return .present(reason: .askedForPage) }
        // Found only through a number. A number is what a reading is made of and what a table
        // cell is made of, so the page does not open — but a drawing still reaches the model when
        // the turn asks about it ("what does the 120 VAC output feed", EK §4).
        if !tokenHits.isEmpty, tokenHits.allSatisfy(CodeTokenizer.isNumber) {
            return turnKind == .question && passageKind == .diagram
                ? .attachToModelOnly(reason: .numbersOnly) : .none(reason: .numbersOnly)
        }
        switch (turnKind, passageKind) {
        case (.question, .diagram): return .present(reason: .diagramForQuestion)
        case (.question, .captioned), (.question, .tableRow): return .attachToModelOnly(reason: .tableNotAskedFor)
        case (_, .diagram): return .attachToModelOnly(reason: .notAQuestion)
        default: return .none(reason: .notAQuestion)
        }
    }
}

/// A table or other captioned page the turn's retrieval found goes to the model as its picture
/// only when its label is one the technician named this turn, or the one `table_lookup` last read
/// (Plan KD P3).
///
/// On the partner's retest an unrelated table retrieved on the turn was attached to the model as
/// its picture: `FigureAutoOpenPolicy` hands any captioned page to the model for a question, and a
/// code book's pages are full of tables. A drawing, and prose that names a figure, keep their
/// rules (EK §4: a wiring question reaches the model with its drawing). The gate only ever
/// narrows a decision, never widens one:
/// - a turn that names a table or figure ("Table 98", "figure 3") opens or attaches no page with
///   another label, the way a named page excludes every other page;
/// - a table (`isTable`) handed to the model alone needs its label among the labels the turn
///   named or the one looked up.
///
/// Labels are read the way the rest of the app reads them: tables through `TableReference`
/// (number, letters, spoken numbers, or one table's title), figures as "Figure N" (the label
/// `ManualFigureTool` asks the index for), and compared without case or spacing
/// (`TableChecks.sameLabel`). Pure.
enum RetrievedFigureLabelGate {

    /// The decision for a retrieved page, narrowed by the labels the turn named and looked up.
    static func apply(_ decision: FigureAutoOpenPolicy.Decision,
                      passageKind: FigureAutoOpenPolicy.PassageKind?,
                      passageLabel: String?,
                      namedLabels: [String],
                      lookedUpLabels: [String] = []) -> FigureAutoOpenPolicy.Decision {
        guard decision.stagesFigure else { return decision }
        if !namedLabels.isEmpty, !matches(passageLabel, any: namedLabels) {
            return .none(reason: .otherLabelNamed)
        }
        guard case .attachToModelOnly = decision, isTable(passageKind: passageKind, label: passageLabel) else {
            return decision
        }
        return matches(passageLabel, any: namedLabels + lookedUpLabels)
            ? .attachToModelOnly(reason: .labelAsked)
            : .none(reason: .labelNotAsked)
    }

    /// The tables and figures the technician's words name, as labels ("Table 98", "Figure 3").
    /// `catalogue` lets a table be named by its title, and a lettered label be read as printed.
    static func namedLabels(in said: String, catalogue: [TableReference.Entry] = []) -> [String] {
        var labels = TableReference.references(in: said, catalogue: catalogue)
        for figure in figureLabels(in: said)
        where !labels.contains(where: { TableChecks.sameLabel($0, figure) }) {
            labels.append(figure)
        }
        return labels
    }

    /// "figure 3", "Fig. 12A" → "Figure 3", "Figure 12A".
    static func figureLabels(in said: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\bfig(?:ure|\.)?\s*(\d+)([A-Za-z])?\b"#) else { return [] }
        var labels: [String] = []
        for match in regex.matches(in: said, range: NSRange(said.startIndex..., in: said)) {
            guard let number = Range(match.range(at: 1), in: said) else { continue }
            let letter = Range(match.range(at: 2), in: said).map { String(said[$0]).uppercased() } ?? ""
            let label = "Figure \(said[number])\(letter)"
            if !labels.contains(label) { labels.append(label) }
        }
        return labels
    }

    /// Whether a retrieved passage is a table's: one of its rows, or a captioned passage whose
    /// label is a table's ("Table 98" — captions in every language are written so, `CaptionWords`).
    static func isTable(passageKind: FigureAutoOpenPolicy.PassageKind?, label: String?) -> Bool {
        if passageKind == .tableRow { return true }
        guard passageKind == .captioned, let label else { return false }
        return label.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("table")
    }

    /// Whether `label` is one of `labels`, compared without case or spacing.
    static func matches(_ label: String?, any labels: [String]) -> Bool {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return false }
        return labels.contains { TableChecks.sameLabel($0, label) }
    }
}
