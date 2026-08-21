import XCTest
@testable import OpenGlasses

/// Plan CU P1 — the bounded ring buffer and in-flight bookkeeping wrapped around `TurnTimeline`.
/// These tests are about the ledger's own invariants (capacity, cohort isolation, drop-harmlessly);
/// `TurnTimeline`'s derivations are pinned separately in `TurnTimelineTests`.
@MainActor
final class TurnLedgerTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    /// Starts, marks (`speechEnd` at 0, `firstAudio` at `latency`), and seals one turn in a single
    /// call, so the aggregate tests below can read as a table of cohort → latency rather than a wall
    /// of `start`/`mark`/`seal` boilerplate.
    @discardableResult
    private func sealTurn(
        latency: TimeInterval,
        backend: TurnBackend? = nil,
        tts: TTSEngine? = nil,
        mic: MicRoute? = nil,
        on ledger: TurnLedger
    ) -> UUID {
        let id = ledger.start(TurnTimeline(backend: backend, ttsEngine: tts, micRoute: mic))
        ledger.mark(id, .speechEnd, at: at(0))
        ledger.mark(id, .firstAudio, at: at(latency))
        ledger.seal(id)
        return id
    }

    // MARK: - Lifecycle: start, mark, seal

    func testStartReturnsTheTimelinesOwnIdAndTracksItInFlight() {
        let ledger = TurnLedger()
        let timeline = TurnTimeline(backend: .direct(.anthropic))
        let id = ledger.start(timeline)

        XCTAssertEqual(id, timeline.id)
        XCTAssertEqual(ledger.inFlightCount, 1)
        XCTAssertEqual(ledger.sealed.count, 0)
        XCTAssertEqual(ledger.turn(id), timeline)
    }

    func testMarkAndSealRoundTripThroughToSealedHistory() {
        let ledger = TurnLedger()
        let id = ledger.start()
        ledger.mark(id, .speechEnd, at: at(0))
        ledger.mark(id, .firstAudio, at: at(1.4))
        ledger.seal(id)

        XCTAssertEqual(ledger.inFlightCount, 0, "sealing must remove the turn from in-flight")
        XCTAssertEqual(ledger.sealed.count, 1)
        XCTAssertEqual(ledger.sealed[0].perceivedLatency ?? .nan, 1.4, accuracy: 0.001)
    }

    func testUpdateAppliesAnArbitraryMutationToTheInFlightTurn() {
        let ledger = TurnLedger()
        let id = ledger.start()
        ledger.update(id) {
            $0.backend = .direct(.groq)
            $0.addToolTime(2.0, iterations: 3)
        }
        ledger.seal(id)

        let recorded = ledger.sealed[0]
        XCTAssertEqual(recorded.backend, .direct(.groq))
        XCTAssertEqual(recorded.toolSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(recorded.toolIterations, 3)
    }

    // MARK: - Drop-harmlessly: unknown and sealed ids

    /// The core safety property: a mark for a turn the ledger has never heard of must not crash and
    /// must not conjure a phantom entry into existence.
    func testMarkForAnUnknownTurnIdIsDroppedHarmlessly() {
        let ledger = TurnLedger()
        let strangerID = UUID()
        ledger.mark(strangerID, .speechEnd, at: at(0))

        XCTAssertEqual(ledger.inFlightCount, 0, "an unknown mark must not create an in-flight entry")
        XCTAssertEqual(ledger.sealed.count, 0)
        XCTAssertNil(ledger.turn(strangerID))
    }

    /// The other half of the contract: a *known* id that has already sealed must also refuse further
    /// marks. Its story is finished, and a late mark rewriting a sealed entry would corrupt an
    /// aggregate that already counted it.
    func testMarkForAnAlreadySealedTurnIsDroppedHarmlessly() {
        let ledger = TurnLedger()
        let id = ledger.start()
        ledger.mark(id, .speechEnd, at: at(0))
        ledger.mark(id, .firstAudio, at: at(1.0))
        ledger.seal(id)

        ledger.mark(id, .spokeDone, at: at(99))   // arrives late, after sealing

        XCTAssertNil(ledger.sealed[0].spokeDoneAt, "the late mark must not reach the sealed copy")
        XCTAssertEqual(ledger.sealed.count, 1, "and it must not resurrect a second entry")
    }

    func testUpdateForAnUnknownOrAlreadySealedTurnIsDroppedHarmlessly() {
        let ledger = TurnLedger()
        let id = ledger.start()
        ledger.seal(id)

        ledger.update(id) { $0.abandoned = true }        // known, but sealed
        ledger.update(UUID()) { $0.model = "ghost" }      // never started at all

        XCTAssertFalse(ledger.sealed[0].abandoned)
        XCTAssertEqual(ledger.sealed.count, 1)
        XCTAssertEqual(ledger.inFlightCount, 0)
    }

    func testSealOfAnUnknownIdIsANoOp() {
        let ledger = TurnLedger()
        ledger.seal(UUID())
        XCTAssertEqual(ledger.sealed.count, 0)
    }

    func testDoubleSealIsANoOpTheSecondTime() {
        let ledger = TurnLedger()
        let id = ledger.start()
        ledger.seal(id)
        ledger.seal(id)
        XCTAssertEqual(ledger.sealed.count, 1)
    }

    // MARK: - Partial (abandoned) turns

    /// An abandoned turn is not a write-off — it still seals, tag and all, and it's still the most
    /// informative record we have of where that turn stopped.
    func testAbandonedTurnStillSeals() {
        let ledger = TurnLedger()
        let id = ledger.start(TurnTimeline(backend: .direct(.local), micRoute: .glasses))
        ledger.mark(id, .speechEnd, at: at(0))
        ledger.mark(id, .commit, at: at(2.0))
        ledger.update(id) { $0.abandoned = true }
        ledger.seal(id)

        XCTAssertEqual(ledger.sealed.count, 1)
        let recorded = ledger.sealed[0]
        XCTAssertTrue(recorded.abandoned)
        XCTAssertEqual(recorded.commitAt, at(2.0), "what it did reach is still on the record")
        XCTAssertNil(recorded.perceivedLatency, "it never reached audio — there is no latency to report")
    }

    // MARK: - Eviction by count

    func testEvictsOldestSealedTurnsOnceOverTheCountCap() {
        let ledger = TurnLedger(maxCount: 3, maxBytes: .max)
        for i in 0..<5 {
            let id = ledger.start(TurnTimeline(model: "turn-\(i)"))
            ledger.seal(id)
        }
        XCTAssertEqual(ledger.sealed.map(\.model), ["turn-2", "turn-3", "turn-4"],
                       "only the 3 most recent survive; the oldest are evicted first")
    }

    func testCountEvictionNeverDropsBelowTheCap() {
        let ledger = TurnLedger(maxCount: 2, maxBytes: .max)
        for _ in 0..<10 {
            let id = ledger.start()
            ledger.seal(id)
        }
        XCTAssertEqual(ledger.sealed.count, 2)
    }

    // MARK: - Eviction by bytes

    /// Same-size turns throughout, so the arithmetic is exact: two units fit under the cap, a third
    /// forces the oldest out, and the count cap (100) never binds at all.
    func testEvictsOldestSealedTurnsOnceOverTheByteCapEvenUnderTheCountCap() {
        let longModelName = String(repeating: "m", count: 500)
        let unitSize = TurnLedger.approximateByteSize(of: TurnTimeline(model: longModelName))
        let ledger = TurnLedger(maxCount: 100, maxBytes: unitSize * 2)

        var ids: [UUID] = []
        for _ in 0..<3 {
            let id = ledger.start(TurnTimeline(model: longModelName))
            ledger.seal(id)
            ids.append(id)
        }

        XCTAssertEqual(ledger.sealed.count, 2, "the count cap (100) never binds; the byte cap does")
        XCTAssertEqual(ledger.sealed.map(\.id), [ids[1], ids[2]], "the oldest is evicted first")
    }

    /// The byte estimate has to actually track what varies, or this whole cap is theatre. A ledger
    /// sized for short model names must evict sooner once the names get long.
    func testByteApproximationGrowsWithTheModelNameLength() {
        let short = TurnLedger.approximateByteSize(of: TurnTimeline(model: "gpt"))
        let long = TurnLedger.approximateByteSize(of: TurnTimeline(model: String(repeating: "x", count: 300)))
        XCTAssertGreaterThan(long, short)

        let empty = TurnLedger.approximateByteSize(of: TurnTimeline())
        XCTAssertLessThanOrEqual(empty, short, "no model name at all must never cost more than a short one")
    }

    // MARK: - Aggregates: never pool across backend × ttsEngine × micRoute

    /// The tagging rule made an executable property: turns that differ only in mic route (or TTS
    /// engine) are two populations, and `stats(for:)` must never blend them into one bucket.
    func testAggregatesNeverPoolAcrossMicRouteBackendOrTTSEngine() {
        let ledger = TurnLedger()

        // Phone mic, ElevenLabs — cluster around 1.0 s.
        for latency in [0.9, 1.0, 1.1] {
            sealTurn(latency: latency, backend: .direct(.anthropic), tts: .elevenLabs, mic: .phone, on: ledger)
        }
        // Same backend and TTS engine, glasses mic — an 8 kHz HFP link is a different population.
        for latency in [4.8, 5.0, 5.2] {
            sealTurn(latency: latency, backend: .direct(.anthropic), tts: .elevenLabs, mic: .glasses, on: ledger)
        }
        // Same backend and mic as the first group, on-device TTS instead of cloud.
        for _ in 0..<3 {
            sealTurn(latency: 2.0, backend: .direct(.anthropic), tts: .kokoro, mic: .phone, on: ledger)
        }

        let byCohort = ledger.stats(for: \.perceivedLatency)
        XCTAssertEqual(byCohort.count, 3, "three distinct cohorts must produce three buckets, never one pooled average")

        let phoneEleven = TurnTimeline.Cohort(backend: .direct(.anthropic), ttsEngine: .elevenLabs, micRoute: .phone)
        let glassesEleven = TurnTimeline.Cohort(backend: .direct(.anthropic), ttsEngine: .elevenLabs, micRoute: .glasses)
        let phoneKokoro = TurnTimeline.Cohort(backend: .direct(.anthropic), ttsEngine: .kokoro, micRoute: .phone)

        XCTAssertEqual(byCohort[phoneEleven]?.count, 3)
        XCTAssertEqual(byCohort[phoneEleven]?.mean ?? .nan, 1.0, accuracy: 0.01)

        XCTAssertEqual(byCohort[glassesEleven]?.count, 3)
        XCTAssertEqual(byCohort[glassesEleven]?.mean ?? .nan, 5.0, accuracy: 0.01,
                       "the glasses-mic turns must not drag the phone cohort's average toward them")

        XCTAssertEqual(byCohort[phoneKokoro]?.count, 3)
        XCTAssertEqual(byCohort[phoneKokoro]?.mean ?? .nan, 2.0, accuracy: 0.01)
    }

    /// Realtime backends carry no TTS engine or mic-route tag of their own (Plan CU: they endpoint
    /// server-side); they must still land in their own cohort rather than merging with Direct mode.
    func testRealtimeBackendIsItsOwnCohortSeparateFromDirectMode() {
        let ledger = TurnLedger()
        sealTurn(latency: 1.0, backend: .direct(.anthropic), on: ledger)
        sealTurn(latency: 1.0, backend: .geminiLive, on: ledger)

        let byCohort = ledger.stats(for: \.perceivedLatency)
        XCTAssertEqual(byCohort.count, 2)
    }

    func testPerceivedLatencyByCohortConvenienceMatchesGenericStats() {
        let ledger = TurnLedger()
        sealTurn(latency: 1.0, backend: .geminiLive, on: ledger)
        XCTAssertEqual(ledger.perceivedLatencyByCohort, ledger.stats(for: \.perceivedLatency))
    }

    // MARK: - Median vs mean

    /// The plan's own framing: "one 30 s outlier turn should not move the headline." Five ordinary
    /// turns plus one very slow one — the mean visibly follows the outlier, the median doesn't.
    func testMedianResistsAnOutlierThatVisiblyMovesTheMean() {
        let ledger = TurnLedger()
        for _ in 0..<5 {
            sealTurn(latency: 1.0, backend: .direct(.groq), on: ledger)
        }
        sealTurn(latency: 30.0, backend: .direct(.groq), on: ledger)

        let cohort = TurnTimeline.Cohort(backend: .direct(.groq), ttsEngine: nil, micRoute: nil)
        let stat = ledger.stats(for: \.perceivedLatency)[cohort]

        XCTAssertEqual(stat?.count, 6)
        XCTAssertEqual(stat?.median ?? .nan, 1.0, accuracy: 0.001,
                       "5 turns at 1.0 s plus one 30 s outlier — the median stays put")
        XCTAssertEqual(stat?.mean ?? .nan, 35.0 / 6.0, accuracy: 0.001,
                       "the mean visibly follows the outlier — exactly why the median ships alongside it")
        XCTAssertGreaterThan(stat?.mean ?? 0, (stat?.median ?? 0) * 4,
                             "the outlier must move the mean far more than it moves the median")
    }

    /// Odd sample count, so the median is a single middle value rather than an average of two —
    /// the other branch of the median calculation from the outlier test above.
    func testMedianOfAnOddCountIsTheMiddleValue() {
        let ledger = TurnLedger()
        for latency in [1.0, 2.0, 9.0] {
            sealTurn(latency: latency, backend: .direct(.local), on: ledger)
        }
        let cohort = TurnTimeline.Cohort(backend: .direct(.local), ttsEngine: nil, micRoute: nil)
        XCTAssertEqual(ledger.stats(for: \.perceivedLatency)[cohort]?.median ?? .nan, 2.0, accuracy: 0.001)
    }

    /// A turn missing the metric entirely (never reached first audio) contributes no data point —
    /// it neither pollutes the bucket nor divides by a phantom zero.
    func testATurnMissingTheMetricDoesNotContributeToItsCohortsStats() {
        let ledger = TurnLedger()
        sealTurn(latency: 1.0, backend: .direct(.anthropic), on: ledger)

        let strandedID = ledger.start(TurnTimeline(backend: .direct(.anthropic)))
        ledger.mark(strandedID, .speechEnd, at: at(0))
        ledger.mark(strandedID, .commit, at: at(1.0))   // never reaches firstAudio
        ledger.update(strandedID) { $0.abandoned = true }
        ledger.seal(strandedID)

        let cohort = TurnTimeline.Cohort(backend: .direct(.anthropic), ttsEngine: nil, micRoute: nil)
        XCTAssertEqual(ledger.sealed.count, 2, "both turns are recorded")
        XCTAssertEqual(ledger.stats(for: \.perceivedLatency)[cohort]?.count, 1,
                       "only the turn that actually reached audio contributes a latency sample")
    }

    // MARK: - Housekeeping: ordering, lookup, reset

    func testSealedHistoryIsChronologicalOldestFirst() {
        let ledger = TurnLedger()
        let first = ledger.start(TurnTimeline(model: "first"))
        ledger.seal(first)
        let second = ledger.start(TurnTimeline(model: "second"))
        ledger.seal(second)
        XCTAssertEqual(ledger.sealed.map(\.model), ["first", "second"])
    }

    func testTurnLooksUpInFlightThenFallsBackToSealed() {
        let ledger = TurnLedger()
        let id = ledger.start(TurnTimeline(model: "in flight"))
        XCTAssertEqual(ledger.turn(id)?.model, "in flight")

        ledger.seal(id)
        XCTAssertEqual(ledger.turn(id)?.model, "in flight", "still findable after sealing")
        XCTAssertNil(ledger.turn(UUID()))
    }

    func testResetClearsBothInFlightAndSealed() {
        let ledger = TurnLedger()
        let inFlightID = ledger.start()
        let sealedID = ledger.start()
        ledger.seal(sealedID)

        ledger.reset()

        XCTAssertEqual(ledger.inFlightCount, 0)
        XCTAssertEqual(ledger.sealed.count, 0)
        XCTAssertNil(ledger.turn(inFlightID))
        XCTAssertNil(ledger.turn(sealedID))
    }

    // MARK: - Debug export

    func testDebugExportListsSealedTurnsAndPerCohortStats() {
        let ledger = TurnLedger()
        sealTurn(latency: 1.25, backend: .direct(.anthropic), tts: .elevenLabs, mic: .phone, on: ledger)

        let abandonedID = ledger.start(TurnTimeline(backend: .direct(.local)))
        ledger.mark(abandonedID, .speechEnd, at: at(0))
        ledger.update(abandonedID) { $0.abandoned = true }
        ledger.seal(abandonedID)

        let export = ledger.debugExport(now: at(100))

        XCTAssertTrue(export.contains("2 turns sealed"))
        XCTAssertTrue(export.contains("0 in flight"))
        XCTAssertTrue(export.contains("ABANDONED"))
        XCTAssertTrue(export.contains("anthropic/elevenLabs/phone"))
        XCTAssertTrue(export.contains("perceived=1.25s"))
    }

    func testDebugExportOnAnEmptyLedgerDoesNotCrashAndSaysSo() {
        let ledger = TurnLedger()
        let export = ledger.debugExport(now: at(0))
        XCTAssertTrue(export.contains("0 turns sealed"))
        XCTAssertTrue(export.contains("no sealed turn has reached first audio"))
    }
}
