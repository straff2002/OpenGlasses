import Foundation

/// The pure half of a graph that changes its mind.
///
/// [[BrainStore]] used to treat every observation as a permanent fact: a repeat was discarded by
/// `INSERT OR IGNORE`, and a changed fact simply sat next to the old one, both rendered in the
/// present tense. This engine decides, over plain values, what a re-observation and the passage of
/// time should do to an edge. Three rules:
///
/// - **Repetition is evidence.** Re-observing an exact `(src, relation, dst)` raises a provisional
///   edge's confidence. Corroboration across two *distinct* sessions promotes it. Repeats inside
///   one session raise confidence but are capped below the promotion bar: a wearer restating
///   something twice in a minute is one claim, not two.
/// - **Functional relations hold one value at a time.** A newer destination for `works_at`,
///   `lives_in`, `married_to` or `leads` retires the incumbent — stamped, never deleted, so it can
///   still be read back as history and a correction has something to restore.
/// - **An unrepeated low-confidence claim expires.** A provisional edge below the confidence floor
///   whose last sighting is older than the expiry window is dropped. This is what makes a wrong
///   guess cost one row for one window rather than forever.
///
/// Pure over values: no SQLite, no `Config`, no clock, no singletons. `now` and `Policy` are
/// parameters, so every rule above is a unit test rather than a wait.
enum BrainDistiller {

    // MARK: - Values

    /// What tier an edge is in. `permanent` is what everything written before this engine existed
    /// is, and what a directly-stated claim still enters as.
    enum State: String, Equatable, Hashable {
        case provisional, permanent, superseded
    }

    /// Every dial the rules turn on. All of it is a parameter so the tests can compress a
    /// fortnight into a millisecond, and so nothing here has to read `Config`.
    struct Policy: Equatable {
        /// Where a guessed claim enters. Deliberately below `confidenceFloor`, so an unrepeated
        /// one expires on its own.
        var provisionalConfidence: Double
        /// Where a directly-stated claim enters (a regex hit, or the `link` action's "told
        /// directly"). This is today's behaviour and the reason nothing existing changes tier.
        var directClaimConfidence: Double
        /// What one further sighting is worth.
        var reinforcementIncrement: Double
        /// The most repetition inside a single session can be worth. Below `promotionThreshold`
        /// on purpose: restating a claim is not corroborating it.
        var sameSessionCeiling: Double
        /// Confidence at or above which a provisional edge becomes permanent.
        var promotionThreshold: Double
        /// How many distinct sessions corroborate a claim into permanence.
        var corroboratingSessions: Int
        /// Below this, a stale provisional edge is dropped.
        var confidenceFloor: Double
        /// How long a provisional edge may go unseen before that applies.
        var expiryWindow: TimeInterval
        /// Relations that hold one value at a time.
        var functionalRelations: Set<String>
        /// The closed vocabulary. A candidate outside it yields no decision at all.
        var allowedRelations: Set<String>
        /// How many ingests may pass before a long session distils without waiting for its end.
        var ingestsBetweenPasses: Int

        static let `default` = Policy(
            provisionalConfidence: 0.5,
            directClaimConfidence: 1.0,
            reinforcementIncrement: 0.15,
            sameSessionCeiling: 0.75,
            promotionThreshold: 0.8,
            corroboratingSessions: 2,
            confidenceFloor: 0.6,
            expiryWindow: 14 * 24 * 60 * 60,
            functionalRelations: RelationOntology.functional,
            allowedRelations: RelationOntology.allowed,
            ingestsBetweenPasses: 20
        )
    }

    /// One stored edge, flattened to the values the rules actually read.
    struct Candidate: Equatable, Hashable {
        let id: String
        let srcName: String
        let relation: String
        let dstName: String
        let state: State
        let confidence: Double
        let observations: Int
        let distinctSessions: Int
        /// When this claim became current. Supersession is by recency of *this*, not of the last
        /// time the claim was restated.
        let validFrom: Date
        /// The last time it was observed. Expiry is by recency of this.
        let lastSeen: Date
        let supersededAt: Date?

        init(id: String, srcName: String, relation: String, dstName: String,
             state: State = .provisional, confidence: Double = 0.5,
             observations: Int = 1, distinctSessions: Int = 1,
             validFrom: Date, lastSeen: Date, supersededAt: Date? = nil) {
            self.id = id
            self.srcName = srcName
            self.relation = relation
            self.dstName = dstName
            self.state = state
            self.confidence = confidence
            self.observations = observations
            self.distinctSessions = distinctSessions
            self.validFrom = validFrom
            self.lastSeen = lastSeen
            self.supersededAt = supersededAt
        }
    }

    /// What to do with one candidate. `confidence` on `promote`/`reinforce` is an *absolute*
    /// value, not a delta — that is what makes re-running `decide` on its own output a no-op.
    enum Decision: Equatable, Hashable {
        case promote(id: String, confidence: Double)
        case reinforce(id: String, confidence: Double)
        case supersede(id: String, at: Date)
        case expire(id: String)
        case keep(id: String)

        var id: String {
            switch self {
            case .promote(let id, _), .reinforce(let id, _), .supersede(let id, _),
                 .expire(let id), .keep(let id):
                return id
            }
        }
    }

    /// Counts of a pass, for the caller and for the log line (counts only, never a name).
    struct Summary: Equatable {
        var considered = 0
        var promoted = 0
        var reinforced = 0
        var superseded = 0
        var expired = 0
        var kept = 0

        /// Rows the pass actually changed.
        var changed: Int { promoted + reinforced + superseded + expired }

        init() {}

        init(_ decisions: [Decision]) {
            considered = decisions.count
            for decision in decisions {
                switch decision {
                case .promote: promoted += 1
                case .reinforce: reinforced += 1
                case .supersede: superseded += 1
                case .expire: expired += 1
                case .keep: kept += 1
                }
            }
        }
    }

    // MARK: - The engine

    /// Decide what becomes of each candidate. Exactly one decision per candidate whose relation is
    /// in the vocabulary; a candidate outside it yields none at all (the graph will not act on a
    /// relation it does not know how to reason about).
    ///
    /// Order-independent — the result depends on the set, not the sequence — and idempotent: apply
    /// the decisions, feed the result back in, and every candidate reads `.keep`.
    static func decide(candidates: [Candidate], now: Date, policy: Policy = .default) -> [Decision] {
        let considered = candidates.filter { policy.allowedRelations.contains($0.relation) }
        var decisions: [String: Decision] = [:]
        /// Everything that counts as current once promotions are applied — the only edges allowed
        /// to take part in supersession. A provisional edge cannot retire a permanent one until it
        /// has been promoted itself.
        var current: [Candidate] = []

        for candidate in considered {
            if candidate.supersededAt != nil || candidate.state == .superseded {
                decisions[candidate.id] = .keep(id: candidate.id)   // history stays as it is
                continue
            }
            switch candidate.state {
            case .superseded:
                decisions[candidate.id] = .keep(id: candidate.id)
            case .permanent:
                decisions[candidate.id] = .keep(id: candidate.id)
                current.append(candidate)
            case .provisional:
                let earned = earnedConfidence(candidate, policy: policy)
                if earned >= policy.promotionThreshold
                    || candidate.distinctSessions >= policy.corroboratingSessions {
                    let confidence = min(1.0, max(earned, policy.promotionThreshold))
                    decisions[candidate.id] = .promote(id: candidate.id, confidence: confidence)
                    current.append(candidate.promoted(to: confidence))
                } else if earned > candidate.confidence {
                    decisions[candidate.id] = .reinforce(id: candidate.id, confidence: earned)
                } else if candidate.confidence < policy.confidenceFloor,
                          now.timeIntervalSince(candidate.lastSeen) > policy.expiryWindow {
                    decisions[candidate.id] = .expire(id: candidate.id)
                } else {
                    decisions[candidate.id] = .keep(id: candidate.id)
                }
            }
        }

        for retired in supersessions(among: current, policy: policy) {
            // Supersession wins over a promotion decided in the same pass: an edge that is no
            // longer current has nothing to be promoted into.
            decisions[retired] = .supersede(id: retired, at: now)
        }

        return decisions.values.sorted { $0.id < $1.id }
    }

    /// The confidence a provisional edge has earned from repetition alone. Absolute — a function
    /// of the tier's entry value and the observation count, never of the stored confidence — so
    /// applying it twice changes nothing. `max` with the stored value keeps it monotone when a
    /// stronger source has already raised the edge.
    static func earnedConfidence(_ candidate: Candidate, policy: Policy) -> Double {
        let repeats = Double(max(0, candidate.observations - 1))
        let earned = policy.provisionalConfidence + policy.reinforcementIncrement * repeats
        let corroborated = candidate.distinctSessions >= policy.corroboratingSessions
        let capped = corroborated ? earned : min(earned, policy.sameSessionCeiling)
        return min(1.0, max(candidate.confidence, capped))
    }

    /// Ids of current edges a newer claim has retired. Only functional relations, only within one
    /// `(source, relation)` group, and only when the group holds more than one destination.
    private static func supersessions(among current: [Candidate], policy: Policy) -> [String] {
        var groups: [String: [Candidate]] = [:]
        for candidate in current where policy.functionalRelations.contains(candidate.relation) {
            groups["\(candidate.srcName.lowercased())\u{1}\(candidate.relation)", default: []]
                .append(candidate)
        }
        var retired: [String] = []
        for (_, group) in groups where group.count > 1 {
            // Newest claim wins; the id breaks a tie so the result never depends on input order.
            let sorted = group.sorted {
                $0.validFrom == $1.validFrom ? $0.id < $1.id : $0.validFrom < $1.validFrom
            }
            retired.append(contentsOf: sorted.dropLast().map(\.id))
        }
        return retired
    }
}

private extension BrainDistiller.Candidate {
    func promoted(to confidence: Double) -> Self {
        BrainDistiller.Candidate(
            id: id, srcName: srcName, relation: relation, dstName: dstName,
            state: .permanent, confidence: confidence, observations: observations,
            distinctSessions: distinctSessions, validFrom: validFrom, lastSeen: lastSeen,
            supersededAt: supersededAt)
    }
}
