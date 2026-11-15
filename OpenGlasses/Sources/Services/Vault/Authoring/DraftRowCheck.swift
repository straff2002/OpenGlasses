import Foundation

/// Plan LW §4a — every row an author would keep, checked against the manual's own page text, pure.
///
/// The rows come from a pasted reply (`PastedDraftParser`) or from the phone's own proposals
/// (`FaultCodeProposals` and its siblings): the same check serves both, and nothing leaves the phone.
///
/// - **Fault code** (`code · label · page`): the cited page is read as a printed page first (the
///   manual's printed-page map), then as a PDF page. The code, normalised (case, spaces, hyphen and
///   the other dashes alike; on a recognised page O/0, I/1 and S/5 too), must be printed there with
///   the label's key words near it. Not there but on exactly one other page: *found on page N*; on
///   several: the list; nowhere: *not in this manual*.
/// - **Model:** every spelling must be printed somewhere in the manual. One printed on a single page,
///   deep in the manual, carries a soft note (`mentionedOnce`).
/// - **Symptom:** only partly checkable. The cited page must share key words with the row's cause
///   and check, and any code or part number in the row must be printed in the manual: *section
///   checked*, never a full tick.
/// - A cited page whose text is unclear: *page text unclear*, neither pass nor fail.
/// - Any row with six or more consecutive words matching the page, or prefilled from the manual by a
///   proposal: *in the manual's words*.
enum DraftRowCheck {

    struct Outcome: Equatable {
        enum Mark: Equatable {
            case checked
            /// Not on the cited page, but on exactly this other one: a suggestion.
            case foundOnAnotherPage(Int)
            /// Not on the cited page, but on these others.
            case foundOnPages([Int])
            /// Not in this manual.
            case notFound
            /// A symptom: the page exists and shares key words with the row; the wording is the author's.
            case sectionChecked
            /// The cited page's text cannot be trusted either way.
            case pageTextUnclear
        }

        var mark: Mark
        /// The PDF page the mark is about: where the row was found, or the unclear page.
        var page: Int?
        /// Six or more consecutive words of the row match the page, or the row was prefilled from it.
        var inManualsWords = false
        /// A fault code: every page the code is printed on, with or without its label, so a row whose
        /// label is wrong can say where the code is.
        var codePages: [Int] = []
        /// A model: the spellings the manual never prints.
        var missingSpellings: [String] = []
        /// A model printed on one page only, past the cover pages: that page.
        var mentionedOnce: Int?
        /// A symptom: the codes and part numbers in the row the manual never prints.
        var missingCodes: [String] = []

        /// What *Keep all checked* keeps.
        var isChecked: Bool { mark == .checked }
    }

    /// The PDF pages at the front of a manual where a model number is expected to appear once (a
    /// cover, a contents): a model printed only there is not *mentioned once*.
    static let coverPages = 4
    /// Consecutive words that make a row *in the manual's words*.
    static let copiedRunLength = 6
    /// How far from a code its label's key words may sit, in words before and after it.
    static let wordsBeforeCode = 15
    static let wordsAfterCode = 40

    // MARK: - Checking

    static func check(_ row: DraftRow, copiedFromManual: Bool = false, in manual: any DraftPageText) -> Outcome {
        var outcome: Outcome
        switch row {
        case .faultCode(let faultCode): outcome = check(faultCode, in: manual)
        case .model(let model): outcome = check(model, in: manual)
        case .symptom(let symptom): outcome = check(symptom, in: manual)
        }
        if copiedFromManual { outcome.inManualsWords = true }
        return outcome
    }

    /// The indices *Keep all checked* keeps.
    static func keepAllChecked(_ outcomes: [Outcome]) -> [Int] {
        outcomes.indices.filter { outcomes[$0].isChecked }
    }

    static func check(_ row: FaultCodeRow, in manual: any DraftPageText) -> Outcome {
        let cited = resolve(row.page, in: manual)
        let labelWords = keyWords(row.label)
        func matches(_ page: Int) -> Bool {
            guard let text = manual.text(onPage: page) else { return false }
            return labelNearCode(code: row.code, labelWords: labelWords, text: text, folding: manual.isRecognised(page: page))
        }
        let codePages = manual.pageNumbers.filter { page in
            manual.text(onPage: page).map { codePositions(row.code, in: tokens(of: $0), folding: manual.isRecognised(page: page)) }?
                .isEmpty == false
        }
        func copied(on page: Int) -> Bool {
            manual.text(onPage: page).map { sharesRun(row.label, with: $0) } ?? false
        }
        if let page = cited.first(where: matches) {
            return Outcome(mark: .checked, page: page, inManualsWords: copied(on: page), codePages: codePages)
        }
        if let unclear = cited.first(where: { manual.isUnclear(page: $0) }) {
            return Outcome(mark: .pageTextUnclear, page: unclear, codePages: codePages)
        }
        let elsewhere = manual.pageNumbers.filter { !cited.contains($0) && matches($0) }
        switch elsewhere.count {
        case 0: return Outcome(mark: .notFound, codePages: codePages)
        case 1: return Outcome(mark: .foundOnAnotherPage(elsewhere[0]), page: elsewhere[0],
                               inManualsWords: copied(on: elsewhere[0]), codePages: codePages)
        default: return Outcome(mark: .foundOnPages(elsewhere), codePages: codePages)
        }
    }

    static func check(_ row: ModelRow, in manual: any DraftPageText) -> Outcome {
        var pagesBySpelling: [(spelling: String, pages: [Int])] = []
        for spelling in row.spellings {
            let pages = manual.pageNumbers.filter { page in
                manual.text(onPage: page).map {
                    !codePositions(spelling, in: tokens(of: $0), folding: manual.isRecognised(page: page)).isEmpty
                } ?? false
            }
            pagesBySpelling.append((spelling, pages))
        }
        let missing = pagesBySpelling.filter { $0.pages.isEmpty }.map(\.spelling)
        let everyPage = Array(Set(pagesBySpelling.flatMap(\.pages))).sorted()
        guard missing.isEmpty else {
            // A manual none of whose text can be read says nothing either way.
            let unreadable = !manual.pageNumbers.isEmpty && manual.pageNumbers.allSatisfy { manual.isUnclear(page: $0) }
            return Outcome(mark: unreadable ? .pageTextUnclear : .notFound, missingSpellings: missing)
        }
        let cited = row.page.map { resolve($0, in: manual) } ?? []
        let page = cited.first(where: everyPage.contains) ?? everyPage.first
        var outcome = Outcome(mark: .checked, page: page)
        if everyPage.count == 1, let only = everyPage.first, only > coverPages { outcome.mentionedOnce = only }
        return outcome
    }

    static func check(_ row: SymptomRow, in manual: any DraftPageText) -> Outcome {
        let cited = resolve(row.page, in: manual)
        let words = keyWords(row.cause + " " + row.check)
        let needed = max(1, (words.count + 2) / 3)
        func shared(_ page: Int) -> Int {
            guard let text = manual.text(onPage: page) else { return 0 }
            let pageWords = Set(CodeTokenizer.words(in: text).map { $0.lowercased() })
            return words.filter { word in pageWords.contains { sameWord($0, word) } }.count
        }
        // A code or a part number has a letter in it; a bare number is a reading or a time.
        let codes = CodeTokenizer.codeTokens(from: [row.symptom, row.cause, row.check].joined(separator: " "))
            .filter { $0.contains(where: \.isLetter) }
        let missingCodes = codes.filter { code in
            !manual.pageNumbers.contains { page in
                manual.text(onPage: page).map {
                    !codePositions(code, in: tokens(of: $0), folding: manual.isRecognised(page: page)).isEmpty
                } ?? false
            }
        }
        func copied(on page: Int) -> Bool {
            guard let text = manual.text(onPage: page) else { return false }
            return [row.symptom, row.cause, row.check].contains { sharesRun($0, with: text) }
        }
        var outcome: Outcome
        if let page = cited.first(where: { shared($0) >= needed }) {
            outcome = Outcome(mark: .sectionChecked, page: page, inManualsWords: copied(on: page))
        } else if let unclear = cited.first(where: { manual.isUnclear(page: $0) }) {
            outcome = Outcome(mark: .pageTextUnclear, page: unclear)
        } else {
            let scored: [(page: Int, shared: Int)] = manual.pageNumbers
                .filter { !cited.contains($0) }
                .map { page -> (page: Int, shared: Int) in (page: page, shared: shared(page)) }
                .filter { $0.shared >= needed }
            let ranked = scored.sorted { a, b in a.shared == b.shared ? a.page < b.page : a.shared > b.shared }
            let elsewhere: [Int] = ranked.prefix(3).map { $0.page }
            switch elsewhere.count {
            case 0: outcome = Outcome(mark: .notFound)
            case 1: outcome = Outcome(mark: .foundOnAnotherPage(elsewhere[0]), page: elsewhere[0],
                                      inManualsWords: copied(on: elsewhere[0]))
            default: outcome = Outcome(mark: .foundOnPages(elsewhere))
            }
        }
        if !missingCodes.isEmpty {
            outcome.mark = .notFound
            outcome.missingCodes = missingCodes
        }
        return outcome
    }

    // MARK: - Pages

    /// The PDF pages a cited page can be: the one the row already knows; else every page printing the
    /// number, then the PDF page of that number. A range ("41-43") is read by its first page.
    static func resolve(_ page: DraftPage, in manual: any DraftPageText) -> [Int] {
        if let physical = page.physical { return [physical] }
        var pages = manual.pages(printed: page.cited)
        let first = page.cited.split(separator: "-").first.map(String.init) ?? page.cited
        if pages.isEmpty, first != page.cited { pages = manual.pages(printed: first) }
        if let number = Int(first), manual.text(onPage: number) != nil, !pages.contains(number) { pages.append(number) }
        return pages
    }

    // MARK: - Words and codes

    /// A page's tokens, in order: runs of letters, digits and dashes, the dashes at either end taken
    /// off. Each dash (hyphen, en and em dash, minus) reads as a hyphen.
    static func tokens(of text: String) -> [String] {
        let dashes = CharacterSet(charactersIn: "-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}")
        let folded = CodeTokenizer.foldedForms(text)
        return folded.components(separatedBy: CharacterSet.alphanumerics.union(dashes).inverted)
            .map { $0.trimmingCharacters(in: dashes) }
            .filter { !$0.isEmpty }
    }

    /// A code or a model as it is compared: uppercase, without spaces or dashes; on a recognised page
    /// O, I and S read as 0, 1 and 5.
    static func codeKey(_ code: String, folding: Bool) -> String {
        let dashes = Set("-\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2212}")
        var key = CodeTokenizer.foldedForms(code).uppercased().filter { !$0.isWhitespace && !dashes.contains($0) }
        if folding {
            key = String(key.map { character -> Character in
                switch character {
                case "O": return "0"
                case "I": return "1"
                case "S": return "5"
                default: return character
                }
            })
        }
        return key
    }

    /// Where `code` is printed among `tokens`: as one token, or as two short ones the page split ("E 9").
    static func codePositions(_ code: String, in tokens: [String], folding: Bool) -> [Int] {
        let wanted = codeKey(code, folding: folding)
        guard !wanted.isEmpty else { return [] }
        var positions: [Int] = []
        for (index, token) in tokens.enumerated() {
            if codeKey(token, folding: folding) == wanted {
                positions.append(index)
            } else if index + 1 < tokens.count, token.count <= 4, tokens[index + 1].count <= 4,
                      codeKey(token + tokens[index + 1], folding: folding) == wanted {
                positions.append(index)
            }
        }
        return positions
    }

    /// Whether the label's key words sit near the code: at least half of them (one, for a label of one
    /// or two) within the window around one of its printings. A label with no key words leaves the
    /// code to stand alone.
    static func labelNearCode(code: String, labelWords: [String], text: String, folding: Bool) -> Bool {
        let pageTokens = tokens(of: text)
        let positions = codePositions(code, in: pageTokens, folding: folding)
        guard !positions.isEmpty else { return false }
        guard !labelWords.isEmpty else { return true }
        let needed = max(1, (labelWords.count + 1) / 2)
        let lowered = pageTokens.map { $0.lowercased() }
        return positions.contains { position in
            let window = lowered[max(0, position - wordsBeforeCode)..<min(lowered.count, position + wordsAfterCode + 1)]
            return labelWords.filter { word in window.contains { sameWord($0, word) } }.count >= needed
        }
    }

    /// The words of `text` that carry its meaning: lowercase, three or more letters, not a function
    /// word and not a bare number, each once.
    static func keyWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return CodeTokenizer.words(in: text).map { $0.lowercased() }.filter { word in
            word.count >= 3 && !CodeTokenizer.isNumber(word) && !stopwords.contains(word) && seen.insert(word).inserted
        }
    }

    /// The same word, allowing for an ending: equal, or both four letters or more with one the other's
    /// start and at most three letters between them ("sensor", "sensors"; "turn", "turning").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 3 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Whether `phrase` shares a run of `copiedRunLength` consecutive words with `text`.
    static func sharesRun(_ phrase: String, with text: String) -> Bool {
        let words = CodeTokenizer.words(in: phrase).map { $0.lowercased() }
        guard words.count >= copiedRunLength else { return false }
        let pageWords = CodeTokenizer.words(in: text).map { $0.lowercased() }
        guard pageWords.count >= copiedRunLength else { return false }
        var runs = Set<String>()
        for start in 0...(pageWords.count - copiedRunLength) {
            runs.insert(pageWords[start..<(start + copiedRunLength)].joined(separator: " "))
        }
        for start in 0...(words.count - copiedRunLength)
            where runs.contains(words[start..<(start + copiedRunLength)].joined(separator: " ")) {
            return true
        }
        return false
    }

    /// English function words a label or a check is phrased with, and words every manual prints.
    /// Written for this check.
    static let stopwords: Set<String> = [
        "the", "and", "for", "with", "not", "but", "are", "was", "were", "has", "have", "had", "this", "that",
        "these", "those", "from", "into", "onto", "over", "under", "when", "then", "than", "there", "their",
        "its", "any", "all", "each", "can", "may", "must", "should", "will", "would", "could", "does", "did",
        "out", "off", "too", "very", "also", "only", "both", "either", "neither", "per", "via", "see", "page",
        "check", "checks", "unit", "units", "manual", "fault", "code", "error", "problem", "cause", "likely"
    ]
}
