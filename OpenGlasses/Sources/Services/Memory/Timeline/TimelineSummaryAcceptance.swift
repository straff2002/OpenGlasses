import Foundation

/// Plan KK — whether a summary the model wrote is kept as a timeline entry. Pure.
///
/// A refused summary costs nothing: the range stays uncovered, the omission note keeps saying so,
/// and a later pass tries again. A kept bad one is re-sent on every turn for the rest of the
/// conversation. So the bar is mechanical and strict — present, finished, bounded, prose — and the
/// reason a summary was refused is a closed set, safe to log, that never carries its text.
enum TimelineSummaryAcceptance {

    /// Why a summary was refused.
    enum Rejection: String, Equatable, Sendable {
        /// Nothing left after trimming.
        case empty
        /// The model stopped at its token limit, so the end of the span may be missing.
        case cutOff
        /// Longer than its tier's bound: a note that size defeats the point of having one.
        case tooLong
        /// A code fence, or text that opens like JSON: not the plain notes the block is labelled as.
        case notPlainText
    }

    enum Verdict: Equatable, Sendable {
        /// Kept, trimmed.
        case accepted(String)
        case rejected(Rejection)
    }

    /// The most characters a summary of one chunk may have (plan: start at 2,400).
    static let chunkCharacterLimit = 2_400
    /// The most a merged entry may have: four chunks' worth, said more briefly (start at 3,200).
    static let mergedCharacterLimit = 3_200

    static func characterLimit(for tier: TimelineEntry.Tier) -> Int {
        switch tier {
        case .chunk: return chunkCharacterLimit
        case .merged: return mergedCharacterLimit
        }
    }

    /// - Parameter finishedNormally: false when the response ended at its token limit (or any way
    ///   other than the model finishing), whatever the text looks like.
    static func evaluate(_ summary: String, tier: TimelineEntry.Tier,
                         finishedNormally: Bool) -> Verdict {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .rejected(.empty) }
        guard finishedNormally else { return .rejected(.cutOff) }
        guard !text.contains("```"), !text.hasPrefix("{"), !text.hasPrefix("[") else {
            return .rejected(.notPlainText)
        }
        guard text.count <= characterLimit(for: tier) else { return .rejected(.tooLong) }
        return .accepted(text)
    }
}
