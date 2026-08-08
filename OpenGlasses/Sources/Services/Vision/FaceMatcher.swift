import Foundation

/// Pure face-embedding matching math for `FaceRecognitionService` — cosine similarity plus
/// best-match-above-threshold selection. Kept separate so the recognition decision is
/// headless-testable without a camera or the Vision framework.
enum FaceMatcher {

    /// Cosine similarity of two equal-length vectors (0 for mismatched/empty inputs).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let mag = sqrt(magA) * sqrt(magB)
        return mag > 0 ? dot / mag : 0
    }

    /// One scored candidate.
    struct Candidate: Equatable {
        let index: Int
        let similarity: Float
    }

    /// What the embedding actually supports saying out loud (Plan CO Item 1).
    ///
    /// `bestMatch` could only ever return a winner, so a near-tie between two enrolled people —
    /// siblings, a parent and child, anyone the embedding finds similar — resolved to whichever
    /// scored a hair higher and was spoken with full confidence. The margin between first and
    /// second place was computed and thrown away, and a wrong name said aloud to someone's face is
    /// among the more expensive mistakes this app can make. Now it can decline to guess.
    enum MatchOutcome: Equatable {
        /// Clears the threshold and beats the runner-up by at least `margin`. The only outcome
        /// permitted to produce a name.
        case confident(Candidate)
        /// Two or more candidates clear the threshold within `margin` of each other, ordered
        /// best-first. Ask; do not assert.
        case ambiguous([Candidate])
        /// Nothing clears the threshold.
        case none
    }

    /// Default similarity gap the leader must open up over the runner-up to be spoken as a fact.
    /// Empirical, and only tunable against real enrolments — a synthetic fixture can prove the
    /// policy but never the number, so this is a starting point, not a finding.
    static let defaultMargin: Float = 0.05

    /// Classify `faceprint` against `candidates`. Candidates whose length differs are skipped
    /// (a stored faceprint from an older embedding version).
    static func match(for faceprint: [Float],
                      among candidates: [[Float]],
                      threshold: Float,
                      margin: Float = defaultMargin) -> MatchOutcome {
        let qualifying = candidates.enumerated()
            .filter { $0.element.count == faceprint.count }
            .map { Candidate(index: $0.offset, similarity: cosineSimilarity(faceprint, $0.element)) }
            // Strictly exceed, matching `bestMatch`'s original behaviour exactly.
            .filter { $0.similarity > threshold }
            .sorted { $0.similarity > $1.similarity }

        guard let leader = qualifying.first else { return .none }
        // A sole qualifying candidate has no runner-up to be confused with, whatever its score.
        guard let runnerUp = qualifying.dropFirst().first else { return .confident(leader) }

        if leader.similarity - runnerUp.similarity >= margin {
            return .confident(leader)
        }
        // Everyone inside the margin of the leader is a live possibility; anyone further back is
        // not, and listing them would only make the question harder to answer.
        let contenders = qualifying.filter { leader.similarity - $0.similarity < margin }
        return .ambiguous(contenders)
    }

    /// Index of the candidate with the highest cosine similarity to `faceprint` that also clears
    /// `threshold`, or nil if none qualify. Candidates whose length differs are skipped.
    ///
    /// Retained for callers that genuinely want top-1 regardless of doubt; reimplemented over
    /// `match` so the two can never disagree about who won. Callers that *speak* a name should use
    /// `match` and honour `.ambiguous`.
    static func bestMatch(for faceprint: [Float], among candidates: [[Float]], threshold: Float) -> Int? {
        switch match(for: faceprint, among: candidates, threshold: threshold) {
        case .confident(let candidate): return candidate.index
        case .ambiguous(let contenders): return contenders.first?.index
        case .none: return nil
        }
    }
}
