import XCTest

/// The eval harnesses' confidence intervals (`EvalIntervals`) and the outcomes files a later run
/// pairs with (`EvalOutcomes`). Pure: no store, no retriever, no app type. Every value is invented.
final class EvalIntervalsTests: XCTestCase {

    /// 40 questions, 17 hits: a key-sized hit@4 of 0.425.
    private let hits: [Double] = Array(repeating: 1, count: 17) + Array(repeating: 0, count: 23)

    func testTheSameSeedGivesTheSameInterval() throws {
        let a = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits, seed: 7))
        let b = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits, seed: 7))
        XCTAssertEqual(a, b)
        XCTAssertEqual(EvalIntervals.bootstrapMeans(hits, resamples: 50, seed: 7),
                       EvalIntervals.bootstrapMeans(hits, resamples: 50, seed: 7))
        XCTAssertNotEqual(EvalIntervals.bootstrapMeans(hits, resamples: 50, seed: 7),
                          EvalIntervals.bootstrapMeans(hits, resamples: 50, seed: 8),
                          "a different seed resamples differently")
    }

    func testTheGeneratorIsTheFixedAlgorithm() {
        // SplitMix64's published first outputs for seed 0, so a seed means the same stream on every
        // machine and Swift version.
        var rng = EvalIntervals.SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        for _ in 0..<1_000 { XCTAssertTrue((0..<7).contains(rng.index(below: 7))) }
    }

    func testTheIntervalHoldsTheMeanAndIsAboutAsWideAsAKeyThisSize() throws {
        let interval = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits))
        XCTAssertEqual(interval.mean, 0.425, accuracy: 1e-12)
        XCTAssertTrue(interval.contains(interval.mean))
        XCTAssertLessThan(interval.lower, interval.mean)
        XCTAssertGreaterThan(interval.upper, interval.mean)
        // A 0.42 rate over 40 questions is good to about ±0.15 (two standard errors of 0.078).
        XCTAssertEqual(interval.width, 0.31, accuracy: 0.06)
        XCTAssertEqual(interval.count, 40)
        XCTAssertEqual(interval.confidence, 0.95)
        XCTAssertEqual(interval.formatted().count, "0.42 [0.28, 0.58]".count)
    }

    func testTheResampleCountIsRespected() throws {
        XCTAssertEqual(EvalIntervals.bootstrapMeans(hits, resamples: 123).count, 123)
        XCTAssertEqual(try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits, resamples: 500)).resamples, 500)
        XCTAssertEqual(try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits)).resamples, 2_000)
        // A wider confidence gives a wider interval from the same resamples.
        let narrow = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits, confidence: 0.5))
        let wide = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: hits, confidence: 0.99))
        XCTAssertLessThan(narrow.width, wide.width)
    }

    func testEdgeCases() throws {
        XCTAssertNil(EvalIntervals.bootstrapInterval(values: []), "no questions, no interval")
        XCTAssertEqual(EvalIntervals.bootstrapMeans([], resamples: 10), [])
        let one = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: [0.5]))
        XCTAssertEqual([one.mean, one.lower, one.upper], [0.5, 0.5, 0.5], "one question: zero width at its value")
        let constant = try XCTUnwrap(EvalIntervals.bootstrapInterval(values: Array(repeating: 1, count: 30)))
        XCTAssertEqual(constant.width, 0)
        XCTAssertEqual(constant.mean, 1)
        XCTAssertNil(EvalIntervals.intervalLine(prefix: "[EVAL]", metrics: [("hit@1", [])]))
    }

    func testIdenticalRunsDifferByNothingWithinNoise() throws {
        let rr: [Double] = [1, 0.5, 0, 0.25, 1, 0, 0.2, 1, 0.333, 0]
        let d = try XCTUnwrap(try EvalIntervals.pairedBootstrap(a: rr, b: rr))
        XCTAssertEqual([d.interval.mean, d.interval.lower, d.interval.upper], [0, 0, 0])
        XCTAssertEqual(d.verdict, .withinNoise)
        XCTAssertEqual(d.formatted, "+0.00 [+0.00, +0.00] within noise")
        XCTAssertNil(try EvalIntervals.pairedBootstrap(a: [], b: []))
    }

    func testAClearlyShiftedPairIsBetterAndTheReverseWorse() throws {
        // The change finds ten more of 40, loses none.
        let after: [Double] = Array(repeating: 1, count: 27) + Array(repeating: 0, count: 13)
        let better = try XCTUnwrap(try EvalIntervals.pairedBootstrap(a: hits, b: after))
        XCTAssertEqual(better.interval.mean, 0.25, accuracy: 1e-12)
        XCTAssertGreaterThan(better.interval.lower, 0)
        XCTAssertEqual(better.verdict, .better)
        XCTAssertEqual(try XCTUnwrap(try EvalIntervals.pairedBootstrap(a: after, b: hits)).verdict, .worse)
    }

    func testOneQuestionEitherWayIsWithinNoise() throws {
        // +1 and −1 on two questions of 40: the point estimate is 0, and so is the verdict; a
        // single extra hit (+0.025) is within noise too.
        var a = hits, b = hits
        b[0] = 0; b[39] = 1
        XCTAssertEqual(try XCTUnwrap(try EvalIntervals.pairedBootstrap(a: a, b: b)).verdict, .withinNoise)
        a = hits; b = hits; b[39] = 1
        let one = try XCTUnwrap(try EvalIntervals.pairedBootstrap(a: a, b: b))
        XCTAssertEqual(one.interval.mean, 0.025, accuracy: 1e-12)
        XCTAssertEqual(one.verdict, .withinNoise, "one question in 40 has not been shown to help")
    }

    func testMismatchedLengthsThrow() {
        XCTAssertThrowsError(try EvalIntervals.pairedBootstrap(a: [1, 0], b: [1])) { error in
            XCTAssertEqual(error as? EvalIntervals.Failure, .mismatchedLengths(baseline: 2, current: 1))
        }
    }

    // MARK: - Outcomes files and pairing

    func testAnOutcomeLineCarriesNumbersAndAHashNeverTheQuestion() throws {
        let question = "how far apart may the invented brackets be"
        let h = EvalOutcomes.hash(question)
        XCTAssertEqual(h.count, EvalOutcomes.hashLength)
        XCTAssertEqual(h, EvalOutcomes.hash("  " + question + "\n"), "surrounding spaces aside, the same question")
        XCTAssertNotEqual(h, EvalOutcomes.hash(question + "?"))
        let outcomes = [EvalOutcome(q: 1, h: h, metrics: ["hit1": 0, "hit4": 1, "rr": 0.25]),
                        EvalOutcome(q: 2, h: EvalOutcomes.hash("another invented question"), metrics: ["cell": 1])]
        let text = try EvalOutcomes.encoded(outcomes)
        XCTAssertFalse(text.contains("invented"))
        XCTAssertTrue(text.hasPrefix("{\"h\":\"\(h)\",\"hit1\":0,\"hit4\":1,\"q\":1,\"rr\":0.25}\n"), text)
        XCTAssertEqual(try EvalOutcomes.decode(text), outcomes)
        XCTAssertThrowsError(try EvalOutcomes.decode(text + "not a line\n"), "a half-read baseline is refused")
    }

    func testRunsPairByHashAndRefuseAKeyThatChangedTooMuch() throws {
        func run(_ texts: [String], hit: (Int) -> Double) -> [EvalOutcome] {
            texts.enumerated().map { EvalOutcome(q: $0 + 1, h: EvalOutcomes.hash($1), metrics: ["hit4": hit($0)]) }
        }
        let texts = (1...40).map { "invented question \($0)" }
        let baseline = run(texts) { $0 < 17 ? 1 : 0 }
        // The same questions, reordered, one added: pairing ignores place.
        let current = run(Array(texts.reversed()) + ["a new invented question"]) { $0 >= 13 ? 1 : 0 }
        let pairing = EvalOutcomes.pair(baseline: baseline, current: current)
        XCTAssertEqual(pairing.paired, 40)
        XCTAssertEqual(pairing.unmatchedCurrent, 1)
        XCTAssertEqual(pairing.unmatchedBaseline, 0)
        XCTAssertTrue(pairing.isComparable)
        let d = try XCTUnwrap(pairing.difference("hit4"))
        XCTAssertEqual(d.interval.count, 40)
        XCTAssertEqual(d.interval.mean, 10.0 / 40, accuracy: 1e-12)
        XCTAssertEqual(d.verdict, .better)
        XCTAssertNil(pairing.difference("rr"), "a metric neither run has")
        let lines = EvalOutcomes.comparisonLines(prefix: "[EVAL]  ", pairing: pairing, metrics: [("hit@4", "hit4")])
        XCTAssertEqual(lines.first, "[EVAL]   vs baseline: paired 40 of 41 (unmatched: 1 here, 0 in the baseline)")
        XCTAssertTrue(lines.last?.hasSuffix("better") == true, lines.joined(separator: "\n"))

        // A question asked twice pairs occurrence by occurrence.
        let twice = run(["same", "same"]) { Double($0) }
        XCTAssertEqual(EvalOutcomes.pair(baseline: twice, current: twice).pairs.map { $0.current.q }, [1, 2])

        // Most of the key rewritten: not compared.
        let rewritten = run(Array(texts.prefix(30)) + (1...10).map { "rewritten \($0)" }) { _ in 1 }
        let refused = EvalOutcomes.pair(baseline: baseline, current: rewritten)
        XCTAssertEqual(refused.paired, 30)
        XCTAssertFalse(refused.isComparable, "30 of 40 is under the 80% floor")
        let refusal = EvalOutcomes.comparisonLines(prefix: "[EVAL]  ", pairing: refused, metrics: [("hit@4", "hit4")])
        XCTAssertEqual(refusal.count, 1)
        XCTAssertTrue(refusal[0].contains("not compared"), refusal[0])
    }
}
