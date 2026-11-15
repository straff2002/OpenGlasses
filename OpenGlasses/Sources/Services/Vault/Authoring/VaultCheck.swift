import Foundation

/// Plan LW §6 — how many of a vault's questions find the page that answers them, pure.
///
/// Each question carries the manual (by its `VaultExpects` key) and the PDF page that should answer
/// it, from the template's starter set or the author's own. The check runs retrieval only, no model
/// and no network; what came back for each question is injected here, in rank order. A question is
/// **found** when one of its first `depth` passages is from an expected manual and covers an expected
/// page. A miss names *what it found instead*. A question with no expected page yet is not scored: it
/// is listed for the author to give it one. *"18 of 20 questions find the right page."*
enum VaultCheck {

    /// A manual and a PDF page.
    struct PageRef: Equatable, Hashable {
        let key: String
        let page: Int
    }

    struct Question: Equatable {
        let text: String
        /// Any of these answers it. Empty: the author has not said which page does.
        let expected: [PageRef]
    }

    /// One retrieved passage: its manual's key and every PDF page it covers (`VaultRetriever.Passage`'s
    /// page, and the pages a chunk packed across).
    struct Retrieved: Equatable, Hashable {
        let key: String
        let pages: [Int]
    }

    struct Miss: Equatable {
        let question: Question
        /// The first passages that came back, up to three, distinct.
        let foundInstead: [Retrieved]
    }

    struct Score: Equatable {
        /// Questions with an expected page.
        let asked: Int
        let found: Int
        let misses: [Miss]
        /// Questions not scored, for want of an expected page.
        let withoutPage: [Question]

        /// Found over asked; 1 when nothing was asked.
        var fraction: Double { asked == 0 ? 1 : Double(found) / Double(asked) }

        /// Whether the score reaches `threshold` (0–1), the author's own bar for the publishing check.
        func meets(_ threshold: Double) -> Bool { fraction + 1e-9 >= threshold }
    }

    /// How many passages, from the top, a question's page may be among.
    static let defaultDepth = 5

    static func isFound(_ question: Question, in retrieved: [Retrieved], depth: Int = defaultDepth) -> Bool {
        let expected = Set(question.expected)
        return retrieved.prefix(depth).contains { passage in
            passage.pages.contains { expected.contains(PageRef(key: passage.key, page: $0)) }
        }
    }

    /// Scores `questions` against what retrieval gave each, `retrieved[i]` for `questions[i]`.
    static func score(_ questions: [Question], retrieved: [[Retrieved]], depth: Int = defaultDepth) -> Score {
        var asked = 0, found = 0
        var misses: [Miss] = []
        var withoutPage: [Question] = []
        for (index, question) in questions.enumerated() {
            guard !question.expected.isEmpty else { withoutPage.append(question); continue }
            asked += 1
            let passages = index < retrieved.count ? retrieved[index] : []
            if isFound(question, in: passages, depth: depth) {
                found += 1
            } else {
                var distinct: [Retrieved] = []
                for passage in passages where !distinct.contains(passage) {
                    distinct.append(passage)
                    if distinct.count == 3 { break }
                }
                misses.append(Miss(question: question, foundInstead: distinct))
            }
        }
        return Score(asked: asked, found: found, misses: misses, withoutPage: withoutPage)
    }

    /// The template's starter questions, each with the pages the author picked for it (`answers`, by
    /// the question's text; the screen offers pages of its `answerPage` kind first), or none yet.
    static func starterQuestions(_ template: TradeTemplate, answers: [String: [PageRef]] = [:]) -> [Question] {
        template.checkQuestions.map { Question(text: $0.text, expected: answers[$0.text] ?? []) }
    }
}
