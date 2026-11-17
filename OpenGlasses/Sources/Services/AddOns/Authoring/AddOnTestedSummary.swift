import Foundation

/// What the review sheet's Tested panel shows for an add-on the assistant built: the sample
/// question, what it answered, every domain the test contacted, how long it took, and the source.
struct AddOnTestedSummary: Equatable, Sendable {
    let sessionID: String
    let goal: String
    let sampleQuestion: String
    let spokenAnswer: String
    let domainsContacted: [String]
    let elapsed: TimeInterval
    let testedAt: Date
    let sourceText: String

    init(sessionID: String, goal: String, sampleQuestion: String, spokenAnswer: String,
         domainsContacted: [String], elapsed: TimeInterval, testedAt: Date, sourceText: String) {
        self.sessionID = sessionID
        self.goal = goal
        self.sampleQuestion = sampleQuestion
        self.spokenAnswer = spokenAnswer
        self.domainsContacted = domainsContacted
        self.elapsed = elapsed
        self.testedAt = testedAt
        self.sourceText = sourceText
    }

    init(draft: AddOnDraftStore.Draft) {
        self.init(sessionID: draft.id, goal: draft.goal, sampleQuestion: draft.sampleQuestion,
                  spokenAnswer: draft.trace.spoken, domainsContacted: draft.trace.hostsContacted,
                  elapsed: draft.trace.elapsed, testedAt: draft.testedAt,
                  sourceText: String(decoding: draft.fileBytes, as: UTF8.self))
    }

    /// "1.4 seconds", rounded to a tenth.
    var elapsedText: String {
        let seconds = (elapsed * 10).rounded() / 10
        return String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) seconds")
    }
}
