import XCTest
@testable import OpenGlasses

/// Plan CO Item 1. `bestMatch` could only return a winner, so a near-tie between two enrolled
/// people was spoken with full confidence. These tests pin the outcome boundaries and prove the
/// retained `bestMatch` still agrees with `match` about who leads.
final class FaceMatchAmbiguityTests: XCTestCase {

    /// Unit vectors in 2-D make cosine similarity exactly `cos(angle)`, so a test can place
    /// candidates at chosen similarities instead of hoping a random vector lands nearby.
    private func vector(at radians: Float) -> [Float] { [cos(radians), sin(radians)] }
    private let probe: [Float] = [1, 0]

    /// Similarity of a candidate placed `radians` off the probe.
    private func similarity(_ radians: Float) -> Float {
        FaceMatcher.cosineSimilarity(probe, vector(at: radians))
    }

    // MARK: - Outcomes

    func testSoleQualifyingCandidateIsConfident() {
        let outcome = FaceMatcher.match(for: probe, among: [vector(at: 0.1)], threshold: 0.5, margin: 0.05)
        guard case .confident(let candidate) = outcome else { return XCTFail("expected .confident, got \(outcome)") }
        XCTAssertEqual(candidate.index, 0)
    }

    /// The defect this plan exists for: two people the embedding cannot separate.
    func testNearTieIsAmbiguousRatherThanTheLeader() {
        let a = vector(at: 0.20)
        let b = vector(at: 0.21)   // a hair further away — the old code would have named `a`
        XCTAssertLessThan(similarity(0.20) - similarity(0.21), 0.05, "fixture must sit inside the margin")

        let outcome = FaceMatcher.match(for: probe, among: [a, b], threshold: 0.5, margin: 0.05)
        guard case .ambiguous(let contenders) = outcome else { return XCTFail("expected .ambiguous, got \(outcome)") }
        XCTAssertEqual(contenders.map(\.index), [0, 1], "ordered best-first")
    }

    /// A clear winner still gets named — the fix must not make recognition useless.
    func testClearLeaderIsStillConfident() {
        let near = vector(at: 0.0)     // similarity 1.0
        let far = vector(at: 0.85)     // ~0.66
        XCTAssertGreaterThan(similarity(0.0) - similarity(0.85), 0.05)

        let outcome = FaceMatcher.match(for: probe, among: [near, far], threshold: 0.5, margin: 0.05)
        guard case .confident(let candidate) = outcome else { return XCTFail("expected .confident, got \(outcome)") }
        XCTAssertEqual(candidate.index, 0)
    }

    /// Boundary: a gap of exactly `margin` is confident (`>=`), so the two branches cannot both
    /// claim the same input.
    func testGapExactlyAtMarginIsConfident() {
        let leader: [Float] = [1, 0]
        let runnerUp: [Float] = [0.9, sqrt(1 - 0.81)]   // similarity exactly 0.9
        let margin = FaceMatcher.cosineSimilarity(probe, leader) - FaceMatcher.cosineSimilarity(probe, runnerUp)

        let outcome = FaceMatcher.match(for: probe, among: [leader, runnerUp], threshold: 0.5, margin: margin)
        guard case .confident = outcome else { return XCTFail("expected .confident at the boundary, got \(outcome)") }
    }

    func testNothingClearingThresholdIsNone() {
        let outcome = FaceMatcher.match(for: probe, among: [vector(at: 1.4)], threshold: 0.9, margin: 0.05)
        XCTAssertEqual(outcome, .none)
    }

    func testEmptyCandidateSetIsNone() {
        XCTAssertEqual(FaceMatcher.match(for: probe, among: [], threshold: 0.5), .none)
    }

    /// Three-way ties list everyone inside the margin, and exclude anyone outside it — listing a
    /// no-hoper would only make the spoken question harder to answer.
    func testAmbiguityListsOnlyCandidatesInsideTheMargin() {
        let a = vector(at: 0.20)
        let b = vector(at: 0.21)
        let distant = vector(at: 0.95)   // clears 0.5, nowhere near the leaders

        let outcome = FaceMatcher.match(for: probe, among: [a, b, distant], threshold: 0.5, margin: 0.05)
        guard case .ambiguous(let contenders) = outcome else { return XCTFail("expected .ambiguous, got \(outcome)") }
        XCTAssertEqual(contenders.map(\.index), [0, 1])
    }

    /// A stored faceprint from an older embedding version has a different length and is skipped —
    /// behaviour inherited from `bestMatch` and easy to lose in the rewrite.
    func testMismatchedLengthCandidatesAreSkipped() {
        let outcome = FaceMatcher.match(for: probe, among: [[1, 0, 0], vector(at: 0.1)], threshold: 0.5)
        guard case .confident(let candidate) = outcome else { return XCTFail("expected .confident, got \(outcome)") }
        XCTAssertEqual(candidate.index, 1, "index must refer to the original array, not the filtered one")
    }

    // MARK: - bestMatch compatibility

    /// `bestMatch` is now implemented over `match`; every existing caller must see what it saw
    /// before, including in the ambiguous case (top-1, as it always did).
    func testBestMatchStillReturnsTopOneInEveryOutcome() {
        XCTAssertEqual(FaceMatcher.bestMatch(for: probe, among: [vector(at: 0.20), vector(at: 0.21)], threshold: 0.5), 0)
        XCTAssertEqual(FaceMatcher.bestMatch(for: probe, among: [vector(at: 0.85), vector(at: 0.0)], threshold: 0.5), 1)
        XCTAssertNil(FaceMatcher.bestMatch(for: probe, among: [vector(at: 1.4)], threshold: 0.9))
        XCTAssertNil(FaceMatcher.bestMatch(for: probe, among: [], threshold: 0.5))
    }

    /// The original required *strictly* exceeding the threshold; a candidate sitting exactly on it
    /// does not qualify.
    func testThresholdIsStrictlyExceeded() {
        let exact: [Float] = [0.5, sqrt(1 - 0.25)]   // similarity exactly 0.5
        XCTAssertNil(FaceMatcher.bestMatch(for: probe, among: [exact], threshold: 0.5))
        XCTAssertEqual(FaceMatcher.match(for: probe, among: [exact], threshold: 0.5), .none)
    }

    // MARK: - Spoken phrasing

    func testSpokenListReadsNaturally() {
        XCTAssertEqual(FaceRecognitionService.spokenList(["Sam"]), "Sam")
        XCTAssertEqual(FaceRecognitionService.spokenList(["Sam", "Alex"]), "Sam or Alex")
        XCTAssertEqual(FaceRecognitionService.spokenList(["Sam", "Alex", "Jo"]), "Sam, Alex or Jo")
        XCTAssertEqual(FaceRecognitionService.spokenList([]), "")
    }
}
