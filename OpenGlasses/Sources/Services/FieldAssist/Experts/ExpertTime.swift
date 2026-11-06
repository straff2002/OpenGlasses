import Foundation

// Plan KM §6, P4 — an expert's time on the job: the expert's reply, checked against the call the
// technician's phone saw, and the billable minutes a contracted expert's rule gives.
//
// **Minutes, never money.** Nothing in this file knows a rate, a currency or an amount (decision
// 6): what the technician's record, read-back and Job tab show is minutes. Rates and amounts live
// only on the statement (`ExpertStatement`), for the device owner or the office.

/// How a contracted expert's minutes are billed (Plan KM P4): the least a job is billed at, then
/// rounding up to a grain. Taken from the organisation's list entry (`EscalationContact.Rate`) at
/// the moment the time becomes known — when the call is placed and when the reply arrives — and
/// kept on the job, so the job's record is a pure function of the job. **No money in it**: the
/// rate per hour and its currency stay on the list, and reach only the statement.
struct ExpertBillingRule: Codable, Equatable, Sendable {
    let minimumMinutes: Int
    let roundingMinutes: Int

    init(minimumMinutes: Int, roundingMinutes: Int) {
        self.minimumMinutes = max(0, minimumMinutes)
        self.roundingMinutes = max(1, roundingMinutes)
    }

    private enum CodingKeys: String, CodingKey { case minimumMinutes, roundingMinutes }

    /// Decoding goes through the init, so a hand-edited job file can't carry a zero grain.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimumMinutes: try c.decode(Int.self, forKey: .minimumMinutes),
                  roundingMinutes: try c.decode(Int.self, forKey: .roundingMinutes))
    }

    /// The minimum first, then up to the grain: 7 minutes at a 15-minute minimum and a 15-minute
    /// grain bill 15; 34 bill 45; 15 bill 15. **Nothing on the clock bills nothing** — the minimum
    /// is for a job that took some time, not for a reply that says none.
    func billableMinutes(for minutes: Int) -> Int {
        guard minutes > 0 else { return 0 }
        let floored = max(minutes, minimumMinutes)
        return (floored + roundingMinutes - 1) / roundingMinutes * roundingMinutes
    }
}

/// The call to an expert as the technician's own phone saw it (Plan KM §4): connected to ended,
/// or — when the connection wasn't seen — placed to ended, summed over the job's calls to that
/// expert. Observed, never reported by anyone.
struct ObservedExpertCallTime: Equatable, Sendable {
    enum MeasuredFrom: String, Codable, Sendable {
        /// Every call counted was seen to connect.
        case connected
        /// At least one call's connection wasn't seen, so it counts from when it was placed.
        case placed
    }

    let minutes: Int
    let measuredFrom: MeasuredFrom
    /// When the last counted call ended.
    let endedAt: Date
}

/// What the reply and the observed call say together (Plan KM decision 5). **Shown, never
/// settled**: the app keeps both figures and says whether they agree; a difference is for the
/// people to resolve.
enum ExpertTimeReconciliation: Equatable, Sendable {
    /// The reply's call minutes are within the tolerance of the call the phone saw.
    case agrees
    /// The reply's call minutes minus the phone's: positive when the reply says more.
    case differs(byMinutes: Int)
    /// No reply came (the expert has no Avenkin, or hasn't sent it): the observed call only.
    case observedCallOnly
    /// A reply, and this phone saw no call to that expert.
    case replyOnly
    /// A reply that carries no call minutes (the expert's app saw no call), and a call this phone
    /// saw: nothing to compare.
    case replyWithoutCallMinutes

    var isDifference: Bool {
        if case .differs = self { return true }
        return false
    }

    /// The sentence the record, the read-back and the statement print.
    func sentence(reportedCallMinutes: Int?, observed: ObservedExpertCallTime?) -> String {
        let seen = observed.map { WorkRecord.minutesPhrase(minutes: $0.minutes) } ?? "no call"
        let placedNote = observed?.measuredFrom == .placed
            ? " (this phone didn't see it connect, so it counts from when it was placed)" : ""
        switch self {
        case .agrees:
            return "The reply's call time agrees with the call this phone saw (\(seen))\(placedNote)."
        case .differs(let by):
            let reported = reportedCallMinutes.map { WorkRecord.minutesPhrase(minutes: $0) } ?? "no call"
            return "The reply's call time differs by \(WorkRecord.minutesPhrase(minutes: abs(by))) from the call "
                + "this phone saw: the reply says \(reported), this phone saw \(seen)\(placedNote). "
                + "The app doesn't settle a difference."
        case .observedCallOnly:
            return "No reply from the expert: this is the call this phone saw, only\(placedNote)."
        case .replyOnly:
            return "The expert's reply only: this phone saw no call to them."
        case .replyWithoutCallMinutes:
            return "The expert's reply carries no call minutes, so it can't be checked against the call "
                + "this phone saw (\(seen))\(placedNote)."
        }
    }

    /// The statement's short column: blank when they agree.
    var statementNote: String {
        switch self {
        case .agrees: return ""
        case .differs(let by): return by > 0 ? "reply \(by) min more than the call seen" : "reply \(-by) min less than the call seen"
        case .observedCallOnly: return "observed call only, no reply"
        case .replyOnly: return "reply only, no call seen"
        case .replyWithoutCallMinutes: return "reply has no call minutes"
        }
    }
}

extension ExpertTimeReconciliation: Codable {
    private enum CodingKeys: String, CodingKey { case result, byMinutes = "by_minutes" }

    private var result: String {
        switch self {
        case .agrees: return "agrees"
        case .differs: return "differs"
        case .observedCallOnly: return "observed_call_only"
        case .replyOnly: return "reply_only"
        case .replyWithoutCallMinutes: return "reply_without_call_minutes"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .result) {
        case "agrees": self = .agrees
        case "differs": self = .differs(byMinutes: try c.decode(Int.self, forKey: .byMinutes))
        case "observed_call_only": self = .observedCallOnly
        case "reply_only": self = .replyOnly
        case "reply_without_call_minutes": self = .replyWithoutCallMinutes
        default:
            throw DecodingError.dataCorruptedError(forKey: .result, in: c, debugDescription: "an unknown reconciliation")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(result, forKey: .result)
        if case .differs(let by) = self { try c.encode(by, forKey: .byMinutes) }
    }
}

/// The comparison (Plan KM §6, decision 5). Pure.
enum ExpertTimeReconciler {

    /// **One minute either way still agrees.** Each side counts whole minutes on its own clock —
    /// the expert's app rounds its call to the nearest minute, and so does this phone — so the same
    /// call can honestly read a minute apart from rounding alone, and the two phones see its
    /// boundaries (ringing, connecting, hanging up) a few seconds apart. Two minutes or more is
    /// more than rounding can make, and is shown as a difference.
    static let toleranceMinutes = 1

    /// The call this phone saw to `expertId`, over every escalation to them on the job that has an
    /// end. Nil when none has ended (nothing was seen, or the call is still up).
    static func observedCall(expertId: String, escalations: [FieldSession.Escalation]) -> ObservedExpertCallTime? {
        var seconds: TimeInterval = 0
        var fromPlaced = false
        var lastEnd: Date?
        for escalation in escalations where escalation.expert?.id == expertId {
            guard let ended = escalation.callEndedAt,
                  let from = escalation.callConnectedAt ?? escalation.callStartedAt else { continue }
            if escalation.callConnectedAt == nil { fromPlaced = true }
            seconds += max(0, ended.timeIntervalSince(from))
            lastEnd = max(lastEnd ?? ended, ended)
        }
        guard let lastEnd else { return nil }
        return ObservedExpertCallTime(minutes: wholeMinutes(seconds),
                                      measuredFrom: fromPlaced ? .placed : .connected, endedAt: lastEnd)
    }

    /// Whole minutes, to the nearest — the rule the expert's clock uses too.
    static func wholeMinutes(_ seconds: TimeInterval) -> Int { Int((max(0, seconds) / 60).rounded()) }

    /// - Parameters:
    ///   - hasReply: whether a time reply arrived.
    ///   - reportedCallMinutes: the reply's call minutes (nil when the expert's app saw none).
    ///   - observed: the call this phone saw.
    static func reconcile(hasReply: Bool, reportedCallMinutes: Int?, observed: ObservedExpertCallTime?) -> ExpertTimeReconciliation {
        guard hasReply else { return .observedCallOnly }
        guard let observed else { return .replyOnly }
        guard let reported = reportedCallMinutes else { return .replyWithoutCallMinutes }
        let difference = reported - observed.minutes
        return abs(difference) <= toleranceMinutes ? .agrees : .differs(byMinutes: difference)
    }
}

/// One expert's time on one job, as the work record carries it (`expert_time`, Plan KM P4): who,
/// which kind, when they took it, their clock, the call (as their reply said and as this phone saw
/// it), the billable minutes for a contracted expert, and how the two agree. Built from the job
/// alone. Pure.
///
/// **Minutes only.** There is no rate, currency or amount field, and a test holds that.
struct ExpertTime: Codable, Equatable, Sendable {

    enum Source: String, Codable, Sendable {
        /// The expert's time reply: their clock is the time.
        case reply
        /// No reply: the call this phone saw is the time, labelled as such.
        case observedCall = "observed_call"
    }

    let expertId: String
    let expertName: String
    let kind: EscalationContact.Kind
    let source: Source
    /// The day the time counts on: the reply's Done, or the end of the observed call.
    let dated: Date
    let handoverId: String?
    let acceptedAt: Date?
    let doneAt: Date?
    /// The expert's own clock, Take this job to Done (it runs through a call taken while the
    /// handover is open). Nil with no reply.
    let reviewMinutes: Int?
    /// Lost after the expert's app was killed with the clock running, as their reply said.
    let uncountedMinutes: Int?
    /// The call minutes the expert's reply carried; nil when their app saw no call, or no reply.
    let callMinutes: Int?
    /// The call this phone saw.
    let observedCallMinutes: Int?
    let observedCallMeasuredFrom: ObservedExpertCallTime.MeasuredFrom?
    /// What counts: the expert's clock when they replied, else the observed call.
    let minutes: Int
    /// A contracted expert's minutes under their rule. Nil for staff — time recorded for the
    /// job's costing, with no billable figure — and for a contracted expert whose rule this phone
    /// never had.
    let billableMinutes: Int?
    let reconciliation: ExpertTimeReconciliation
    /// How many coaching replies the expert's time reply says they sent for this handover, and
    /// how many of those this job never received: "a difference points at a reply one side never
    /// got". Nil when the reply says nothing of coaching (an older app, or no reply).
    let coachingRepliesSent: Int?
    let coachingRepliesNotReceived: Int?

    enum CodingKeys: String, CodingKey {
        case kind, source, dated, minutes, reconciliation
        case expertId = "expert_id"
        case expertName = "expert_name"
        case handoverId = "handover_id"
        case acceptedAt = "accepted_at"
        case doneAt = "done_at"
        case reviewMinutes = "review_minutes"
        case uncountedMinutes = "uncounted_minutes"
        case callMinutes = "call_minutes"
        case observedCallMinutes = "observed_call_minutes"
        case observedCallMeasuredFrom = "observed_call_measured_from"
        case billableMinutes = "billable_minutes"
        case coachingRepliesSent = "coaching_replies_sent"
        case coachingRepliesNotReceived = "coaching_replies_not_received"
    }

    /// "Sam Okafor (contracted expert)".
    var credit: String { CoachingCredit.text(name: expertName, kind: kind) }

    // MARK: - Building

    /// One entry per expert the job called or heard back from, in the order they first appear.
    /// An expert with neither a reply nor an ended call has no time yet, and no entry.
    static func build(session: FieldSession) -> [ExpertTime] {
        let replies = session.expertReplies ?? []
        var order: [String] = []
        var snapshots: [String: ExpertSnapshot] = [:]
        func note(_ expert: ExpertSnapshot) {
            if snapshots[expert.id] == nil { order.append(expert.id) }
            snapshots[expert.id] = snapshots[expert.id] ?? expert
        }
        for escalation in session.escalations { if let expert = escalation.expert { note(expert) } }
        for reply in replies { note(reply.expert) }

        let coachingReceived = Set((session.expertCoaching ?? []).map(\.coachingId))
        return order.compactMap { id -> ExpertTime? in
            // The reply as the job's own sent record names the expert, else the call's snapshot.
            let reply = replies.filter { $0.expert.id == id }
                .max { ($0.doneAt, $0.receivedAt) < ($1.doneAt, $1.receivedAt) }
            let expert = reply?.expert ?? snapshots[id]!
            let observed = ExpertTimeReconciler.observedCall(expertId: id, escalations: session.escalations)
            guard reply != nil || observed != nil else { return nil }
            let minutes = reply?.minutes ?? observed?.minutes ?? 0
            let rule = reply?.billing
                ?? session.escalations.last(where: { $0.expert?.id == id && $0.billing != nil })?.billing
            let billable = expert.kind == .contracted ? rule?.billableMinutes(for: minutes) : nil
            let sentCoaching = reply?.coachingReplyIds
            return ExpertTime(
                expertId: id, expertName: expert.name, kind: expert.kind,
                source: reply == nil ? .observedCall : .reply,
                dated: reply?.doneAt ?? observed!.endedAt,
                handoverId: reply?.handoverId, acceptedAt: reply?.acceptedAt, doneAt: reply?.doneAt,
                reviewMinutes: reply?.minutes, uncountedMinutes: reply?.uncountedMinutes,
                callMinutes: reply?.callMinutes,
                observedCallMinutes: observed?.minutes, observedCallMeasuredFrom: observed?.measuredFrom,
                minutes: minutes, billableMinutes: billable,
                reconciliation: ExpertTimeReconciler.reconcile(hasReply: reply != nil,
                                                               reportedCallMinutes: reply?.callMinutes,
                                                               observed: observed),
                coachingRepliesSent: sentCoaching.map(\.count),
                coachingRepliesNotReceived: sentCoaching.map { $0.filter { !coachingReceived.contains($0) }.count })
        }
    }

    private var observed: ObservedExpertCallTime? {
        guard let observedCallMinutes, let observedCallMeasuredFrom else { return nil }
        return ObservedExpertCallTime(minutes: observedCallMinutes, measuredFrom: observedCallMeasuredFrom, endedAt: dated)
    }

    // MARK: - The record's words (minutes, never a rate)

    var lines: [String] {
        var head: String
        switch source {
        case .reply:
            head = "Expert time: \(credit) — \(WorkRecord.minutesPhrase(minutes: minutes)) on their clock"
            if let uncountedMinutes, uncountedMinutes > 0 {
                head += " (\(WorkRecord.minutesPhrase(minutes: uncountedMinutes)) not counted after their app closed)"
            }
        case .observedCall:
            head = "Expert time: \(credit) — \(WorkRecord.minutesPhrase(minutes: minutes)) on the call this phone saw"
        }
        if let billableMinutes { head += "; \(billableMinutes) billable" }
        var lines = [head + "."]
        if source == .reply, let callMinutes {
            lines.append("  Call, by their reply: \(WorkRecord.minutesPhrase(minutes: callMinutes)).")
        }
        lines.append("  " + reconciliation.sentence(reportedCallMinutes: callMinutes, observed: observed))
        if let sent = coachingRepliesSent, sent > 0 {
            let missing = coachingRepliesNotReceived ?? 0
            lines.append(missing == 0
                         ? "  Coaching steps: \(sent == 1 ? "1 reply" : "\(sent) replies") sent, all on this job."
                         : "  Coaching steps: \(sent == 1 ? "1 reply" : "\(sent) replies") sent, \(missing) never reached this job.")
        }
        return lines
    }
}

/// Whether the customer's report carries expert time and the expert's credit (Plan KM decision
/// 8). Pure.
///
/// **Off unless the organisation turns it on.** What the customer is billed is the organisation's
/// business. With a profile in force only the profile decides — absent means off, whatever the
/// phone had stored — so a technician can't turn it on under an organisation; with no profile the
/// device owner is the organisation and decides in Field Assist › Experts.
enum ExpertTimeAudience {
    static func customerShowsExpertTime(managed: Bool, owned: Bool?, stored: Bool) -> Bool {
        managed ? (owned ?? false) : stored
    }

    /// The words that stand in for an expert's name on a customer's report with the switch off.
    static let uncreditedSteps = "Steps walked on this job"
    static let uncreditedCall = "Called an expert."
}
