import XCTest
@testable import OpenGlasses

/// The rules that let the graph change its mind, tested as pure values.
///
/// Every case here is a rule from the design, stated once: repetition is evidence, functional
/// relations hold one value at a time, and an unrepeated low-confidence claim expires. Nothing
/// touches SQLite or a clock — `now` and `Policy` are arguments, so a fortnight costs nothing.
final class BrainDistillerTests: XCTestCase {

    private let policy = BrainDistiller.Policy.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private func candidate(_ id: String,
                           src: String = "Maria",
                           relation: String = "lives_in",
                           dst: String = "Wellington",
                           state: BrainDistiller.State = .provisional,
                           confidence: Double? = nil,
                           observations: Int = 1,
                           distinctSessions: Int = 1,
                           validFromDaysAgo: Double = 0,
                           lastSeenDaysAgo: Double = 0,
                           supersededAt: Date? = nil) -> BrainDistiller.Candidate {
        let day: TimeInterval = 24 * 60 * 60
        return BrainDistiller.Candidate(
            id: id, srcName: src, relation: relation, dstName: dst, state: state,
            confidence: confidence ?? (state == .provisional ? policy.provisionalConfidence : 1.0),
            observations: observations, distinctSessions: distinctSessions,
            validFrom: now.addingTimeInterval(-validFromDaysAgo * day),
            lastSeen: now.addingTimeInterval(-lastSeenDaysAgo * day),
            supersededAt: supersededAt)
    }

    /// Apply decisions to their candidates, the way `BrainStore.distill` applies them to rows.
    /// Lets a test assert that re-running the engine on its own output is a no-op.
    private func apply(_ decisions: [BrainDistiller.Decision],
                       to candidates: [BrainDistiller.Candidate]) -> [BrainDistiller.Candidate] {
        var byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        for decision in decisions {
            guard let old = byID[decision.id] else { continue }
            switch decision {
            case .promote(_, let confidence):
                byID[old.id] = BrainDistiller.Candidate(
                    id: old.id, srcName: old.srcName, relation: old.relation, dstName: old.dstName,
                    state: .permanent, confidence: confidence, observations: old.observations,
                    distinctSessions: old.distinctSessions, validFrom: old.validFrom,
                    lastSeen: old.lastSeen, supersededAt: old.supersededAt)
            case .reinforce(_, let confidence):
                byID[old.id] = BrainDistiller.Candidate(
                    id: old.id, srcName: old.srcName, relation: old.relation, dstName: old.dstName,
                    state: old.state, confidence: confidence, observations: old.observations,
                    distinctSessions: old.distinctSessions, validFrom: old.validFrom,
                    lastSeen: old.lastSeen, supersededAt: old.supersededAt)
            case .supersede(_, let at):
                byID[old.id] = BrainDistiller.Candidate(
                    id: old.id, srcName: old.srcName, relation: old.relation, dstName: old.dstName,
                    state: .superseded, confidence: old.confidence, observations: old.observations,
                    distinctSessions: old.distinctSessions, validFrom: old.validFrom,
                    lastSeen: old.lastSeen, supersededAt: at)
            case .expire:
                byID[old.id] = nil
            case .keep:
                break
            }
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    // MARK: - Repetition is evidence

    /// A second sighting is worth confidence but not permanence: one row, a higher number.
    func testASecondObservationReinforcesRatherThanPromoting() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", observations: 2)], now: now, policy: policy)
        XCTAssertEqual(decisions, [.reinforce(id: "a", confidence: 0.65)])
    }

    /// Corroboration is across conversations. Two distinct sessions promote…
    func testTwoDistinctSessionsPromote() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", observations: 2, distinctSessions: 2)],
            now: now, policy: policy)
        XCTAssertEqual(decisions, [.promote(id: "a", confidence: 0.8)])
    }

    /// …and restating something four times in one breath does not, however confident it gets.
    /// The same-session ceiling sits below the promotion threshold precisely for this.
    func testRepeatsInsideOneSessionNeverPromote() {
        for observations in 2...5 {
            let decisions = BrainDistiller.decide(
                candidates: [candidate("a", observations: observations)], now: now, policy: policy)
            for decision in decisions {
                if case .promote = decision {
                    XCTFail("\(observations) same-session observations must not promote")
                }
            }
        }
    }

    /// A directly stated claim — a regex hit, or the `link` action's "told directly" — enters at
    /// full confidence and is permanent on the first pass rather than serving a probation.
    func testDirectlyStatedClaimPromotesImmediately() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", confidence: policy.directClaimConfidence)],
            now: now, policy: policy)
        XCTAssertEqual(decisions, [.promote(id: "a", confidence: 1.0)])
    }

    // MARK: - Functional relations

    /// A newer `lives_in` retires the older one — and keeps it, stamped, as history.
    func testFunctionalRelationSupersedesTheIncumbentAndKeepsIt() {
        let incumbent = candidate("old", dst: "Wellington", state: .permanent, validFromDaysAgo: 30)
        let arrival = candidate("new", dst: "Auckland", state: .permanent, validFromDaysAgo: 1)
        let decisions = BrainDistiller.decide(candidates: [incumbent, arrival], now: now, policy: policy)
        XCTAssertEqual(Set(decisions), [.supersede(id: "old", at: now), .keep(id: "new")])
        XCTAssertFalse(decisions.contains { if case .expire = $0 { return true } else { return false } },
                       "History is stamped, never deleted")
    }

    /// A non-functional relation accumulates: two boards, two schools, two investments are all
    /// true at once, and retiring either would be a lie.
    func testNonFunctionalRelationKeepsBoth() {
        let first = candidate("a", relation: "studied_at", dst: "Otago",
                              state: .permanent, validFromDaysAgo: 30)
        let second = candidate("b", relation: "studied_at", dst: "Victoria",
                               state: .permanent, validFromDaysAgo: 1)
        let decisions = BrainDistiller.decide(candidates: [first, second], now: now, policy: policy)
        XCTAssertEqual(Set(decisions), [.keep(id: "a"), .keep(id: "b")])
    }

    /// A guess cannot retire a fact. Until the provisional edge is itself corroborated, the
    /// permanent incumbent stays current — the defence against one misread sentence erasing a
    /// correct answer.
    func testProvisionalEdgeCannotSupersedeAPermanentOne() {
        let incumbent = candidate("old", dst: "Wellington", state: .permanent, validFromDaysAgo: 30)
        let guess = candidate("guess", dst: "Berlin", state: .provisional, validFromDaysAgo: 1)
        let decisions = BrainDistiller.decide(candidates: [incumbent, guess], now: now, policy: policy)
        XCTAssertTrue(decisions.contains(.keep(id: "old")), "The fact stays current")
        XCTAssertFalse(decisions.contains(.supersede(id: "old", at: now)))
    }

    /// Once the guess *is* corroborated it takes over in the same pass — promotion and
    /// supersession are one decision about the same set, not two passes apart.
    func testAPromotedEdgeSupersedesInTheSamePass() {
        let incumbent = candidate("old", dst: "Wellington", state: .permanent, validFromDaysAgo: 30)
        let arrival = candidate("new", dst: "Berlin", state: .provisional,
                                observations: 2, distinctSessions: 2, validFromDaysAgo: 1)
        let decisions = BrainDistiller.decide(candidates: [incumbent, arrival], now: now, policy: policy)
        XCTAssertEqual(Set(decisions), [.supersede(id: "old", at: now),
                                        .promote(id: "new", confidence: 0.8)])
    }

    // MARK: - Expiry

    /// Said once, a fortnight ago, never again: dropped. This is what makes a wrong guess cost one
    /// row for one window rather than forever.
    func testUnrepeatedSubFloorProvisionalExpires() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", lastSeenDaysAgo: 20)], now: now, policy: policy)
        XCTAssertEqual(decisions, [.expire(id: "a")])
    }

    /// Repeated even once, it is above the floor and stays — the window is for claims nothing
    /// ever corroborated.
    func testRepeatedProvisionalDoesNotExpire() {
        let repeated = candidate("a", observations: 2, lastSeenDaysAgo: 20)
        let first = BrainDistiller.decide(candidates: [repeated], now: now, policy: policy)
        XCTAssertEqual(first, [.reinforce(id: "a", confidence: 0.65)])
        let settled = apply(first, to: [repeated])
        XCTAssertEqual(BrainDistiller.decide(candidates: settled, now: now, policy: policy),
                       [.keep(id: "a")])
    }

    /// A fresh guess is not stale yet, however low its confidence.
    func testRecentProvisionalIsKeptEvenBelowTheFloor() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", lastSeenDaysAgo: 1)], now: now, policy: policy)
        XCTAssertEqual(decisions, [.keep(id: "a")])
    }

    // MARK: - Shape of the engine

    /// The result depends on the set, not the sequence it arrived in.
    func testDecideIsOrderIndependent() {
        let candidates = [
            candidate("old", dst: "Wellington", state: .permanent, validFromDaysAgo: 30),
            candidate("new", dst: "Auckland", state: .permanent, validFromDaysAgo: 1),
            candidate("stale", relation: "knows", dst: "Carlos", lastSeenDaysAgo: 40),
            candidate("warm", relation: "knows", dst: "Dana", observations: 2),
        ]
        let forwards = BrainDistiller.decide(candidates: candidates, now: now, policy: policy)
        let backwards = BrainDistiller.decide(candidates: candidates.reversed(), now: now, policy: policy)
        XCTAssertEqual(forwards, backwards)
    }

    /// Applying the decisions and re-running reaches a fixed point: nothing is promoted twice,
    /// nothing is reinforced forever. The confidences the engine emits are absolute values, which
    /// is what buys this.
    func testDecideIsIdempotentOnItsOwnOutput() {
        let candidates = [
            candidate("old", dst: "Wellington", state: .permanent, validFromDaysAgo: 30),
            candidate("new", dst: "Auckland", state: .permanent, validFromDaysAgo: 1),
            candidate("promoted", relation: "works_at", dst: "Acme",
                      observations: 2, distinctSessions: 2),
            candidate("warm", relation: "knows", dst: "Dana", observations: 2),
            candidate("stale", relation: "knows", dst: "Carlos", lastSeenDaysAgo: 40),
        ]
        let first = BrainDistiller.decide(candidates: candidates, now: now, policy: policy)
        let settled = apply(first, to: candidates)
        let second = BrainDistiller.decide(candidates: settled, now: now, policy: policy)
        XCTAssertTrue(second.allSatisfy { if case .keep = $0 { return true } else { return false } },
                      "A second pass over settled rows must change nothing: \(second)")
        XCTAssertEqual(apply(second, to: settled), settled)
    }

    /// A relation outside the closed vocabulary is not merely left alone — it produces no decision
    /// at all. The graph does not reason about predicates it never agreed to store.
    func testOffOntologyRelationYieldsNoDecision() {
        let decisions = BrainDistiller.decide(
            candidates: [candidate("a", relation: "vibes_with", dst: "Berlin", lastSeenDaysAgo: 40)],
            now: now, policy: policy)
        XCTAssertTrue(decisions.isEmpty)
    }

    /// Already-retired history is inert: a pass neither revives it nor expires it.
    func testSupersededEdgesAreLeftAlone() {
        let retired = candidate("old", dst: "Wellington", state: .superseded,
                                lastSeenDaysAgo: 400, supersededAt: now.addingTimeInterval(-1000))
        XCTAssertEqual(BrainDistiller.decide(candidates: [retired], now: now, policy: policy),
                       [.keep(id: "old")])
    }

    /// The summary is what the log line and the caller read, so it counts what happened.
    func testSummaryCountsEachKind() {
        let summary = BrainDistiller.Summary([
            .promote(id: "a", confidence: 0.8), .reinforce(id: "b", confidence: 0.65),
            .supersede(id: "c", at: now), .expire(id: "d"), .keep(id: "e"),
        ])
        XCTAssertEqual(summary.considered, 5)
        XCTAssertEqual(summary.changed, 4)
        XCTAssertEqual(summary.kept, 1)
    }
}
