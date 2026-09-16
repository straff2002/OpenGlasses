import Foundation

/// What happened to one agent result on its way to the wearer (Plan FE P4).
///
/// Before this, `AgentSessionService.finish` spoke the summary through a fire-and-forget closure
/// and moved on. "Delivered" meant "playback was requested", which is the same thing it means in
/// the audible-lifecycle coordinator and the cue gate — a reasonable meaning for a chime, and the
/// wrong one for the only report a wearer will get of work they dispatched and then walked away
/// from. A result read out over a barge-in, or withheld because the glasses were off, was
/// indistinguishable from one the wearer actually heard.
///
/// The record below is the distinction, kept per `(run, resultRevision)`:
///
/// * **`resultRevision`** — a run can report its outcome more than once. A later terminal poll
///   with different fields, or a re-summarised result, is a *new* revision with its own delivery
///   and its own acknowledgement; an identical repeat is the same revision and is neither
///   re-spoken nor re-recorded.
/// * **`state`** — `pending` before the speech service has been asked, `playing` while it is
///   speaking, and then whatever actually happened. `completed` is playback finishing, nothing
///   more (see `SpeechDeliveryOutcome`).
/// * **`ackState`** — whether the endpoint was told, kept separate from `state` on purpose. An
///   acknowledgement that fails does **not** make a completed task incomplete; it makes the
///   endpoint's knowledge incomplete, and only that.
struct AgentResultDelivery: Equatable, Codable {

    /// Where the result has got to. Ordered as it progresses; the last four are terminal.
    enum State: String, Equatable, Codable {
        /// Recorded before the speech service is asked, so a crash between the two is visible.
        case pending
        /// Handed to the speech service, which has not reported back.
        case playing
        /// Playback ran to the end of the summary.
        case completed
        /// Playback was cut short — barge-in, stop, or a newer utterance.
        case interrupted
        /// Nothing was played: muted, no route, silent mode, backgrounded.
        case suppressed
        /// Playback broke, or no engine could speak it.
        case failed

        /// Whether the wearer is still owed these words.
        var owesReplay: Bool { self == .interrupted || self == .suppressed }
    }

    /// Why an acknowledgement is not in hand. A closed vocabulary — an endpoint's own words never
    /// reach it, and neither does an HTTP body.
    enum AckFailure: String, Equatable, Codable {
        /// There is nobody to tell: no ack endpoint configured, or a harness with no ack channel.
        /// Not a problem — most endpoints do not ask to be told — and never spoken.
        case unsupported
        /// The delivery did not complete, so there is nothing truthful to acknowledge.
        case notCompleted
        /// A newer result revision arrived before this one's acknowledgement landed. The old
        /// revision is abandoned rather than acknowledged late: an ack naming revision 0 arriving
        /// after revision 1 was read out would tell the endpoint to suppress the wrong thing.
        case superseded
        /// The endpoint answered with an error status.
        case endpointRefused
        /// The request never got an answer, after the bounded retries.
        case transport
    }

    /// Whether the endpoint has been told about this revision.
    enum AckState: Equatable, Codable {
        /// Nothing has been attempted yet.
        case pending
        /// The endpoint accepted the acknowledgement for this exact revision.
        case acknowledged
        /// It was not sent, or it did not land. The task stays completed regardless.
        case unacknowledged(reason: AckFailure)

        var isAcknowledged: Bool { self == .acknowledged }

        /// A fixed token for the log and the status line.
        var token: String {
            switch self {
            case .pending: return "pending"
            case .acknowledged: return "acknowledged"
            case .unacknowledged(let reason): return "unacknowledged-\(reason.rawValue)"
            }
        }
    }

    let runID: String
    /// Which report of this run's outcome this is: 0 for the first, incremented per distinct result.
    let resultRevision: Int
    var state: State
    var ackState: AckState
    /// When the record last changed.
    var at: Date
    /// True only for a record read back from disk at launch — never persisted, never set live.
    /// A reloaded record is the one case where we are guessing about something that already
    /// happened, so it is marked rather than blended in with records we watched happen.
    var reloaded = false

    init(runID: String, resultRevision: Int, state: State = .pending,
         ackState: AckState = .pending, at: Date, reloaded: Bool = false) {
        self.runID = runID
        self.resultRevision = resultRevision
        self.state = state
        self.ackState = ackState
        self.at = at
        self.reloaded = reloaded
    }

    private enum CodingKeys: String, CodingKey {
        case runID, resultRevision, state, ackState, at
    }

    /// The identity the acknowledgement is bound to.
    var identity: Identity { Identity(runID: runID, resultRevision: resultRevision) }

    struct Identity: Hashable, Equatable {
        let runID: String
        let resultRevision: Int
    }

    /// Whether the wearer is still owed these words.
    var owesReplay: Bool { state.owesReplay }

    /// Whether we cannot say, after a relaunch, that the wearer heard this.
    ///
    /// Only a record that was still `pending` or `playing` when the process went away qualifies:
    /// we asked for playback and never learned how it ended, so "you already heard it" and "you
    /// never heard it" are equally unsupported. A record that reached a terminal state was written
    /// with that state, and there is nothing ambiguous about reading it back.
    ///
    /// Note the deliberate narrowness. A `completed` delivery whose ack never landed is ambiguous
    /// **to the endpoint** (`ackIsUnresolved`), not to the wearer — telling them "I may have
    /// already read you that" because a POST failed would be a false doubt.
    var deliveryIsAmbiguous: Bool {
        reloaded && (state == .pending || state == .playing)
    }

    /// Whether the endpoint's knowledge of this revision is unsettled. Never spoken; it is the
    /// honest answer to "was this delivered exactly once", which is **no**.
    var ackIsUnresolved: Bool {
        guard state == .completed else { return false }
        switch ackState {
        case .acknowledged: return false
        case .pending: return true
        case .unacknowledged(let reason): return reason != .unsupported
        }
    }
}

// MARK: - The acknowledgement

/// One acknowledgement of one delivered result revision (Plan FE P4).
///
/// `ackID` is derived from `(runID, resultRevision)` and nothing else, so every retry of the same
/// acknowledgement carries the same id and an endpoint that already recorded it can treat the
/// repeat as a no-op. It is derived rather than minted so it survives a relaunch: an ack retried
/// after the app restarted would otherwise arrive as a second, unrelated acknowledgement.
struct AgentDeliveryAck: Equatable {
    let runID: String
    let resultRevision: Int
    /// The playback state being reported. Only `.completed` is ever sent — see `for(_:)`.
    let deliveryState: AgentResultDelivery.State
    let ackID: String

    /// Build the acknowledgement for a delivery, or `nil` when there is nothing honest to send.
    ///
    /// **Only completed playback is acknowledged.** A queued, suppressed or interrupted result
    /// acknowledged as delivered is precisely the lie this phase exists to remove: it would let an
    /// endpoint suppress re-delivery of a result the wearer never heard.
    static func `for`(_ delivery: AgentResultDelivery) -> AgentDeliveryAck? {
        guard delivery.state == .completed else { return nil }
        return AgentDeliveryAck(runID: delivery.runID,
                                resultRevision: delivery.resultRevision,
                                deliveryState: .completed,
                                ackID: id(runID: delivery.runID, revision: delivery.resultRevision))
    }

    /// Stable per `(run, revision)`. FNV-1a, not `hashValue`, which is per-process seeded.
    static func id(runID: String, revision: Int) -> String {
        "ack-" + AgentQuestion.fnv1a("\(runID)\u{1}\(revision)")
    }

    /// The POST body. Fixed keys — an acknowledgement carries no wearer content and no endpoint
    /// content, only which revision of which run finished playing and the id that makes a repeat
    /// recognisable.
    var body: [String: Any] {
        [
            "runId": runID,
            "resultRevision": resultRevision,
            "deliveryState": deliveryState.rawValue,
            "ackId": ackID,
        ]
    }
}

// MARK: - Result identity

extension AgentRunResult {
    /// A stable fingerprint of everything the harness reported about a run's outcome.
    ///
    /// Two terminal polls that report the same fields are the same result — the endpoint saying
    /// the same thing twice, which must not be read out twice or acknowledged twice. One that
    /// reports *different* fields is a revised result and gets its own revision, even when the
    /// spoken summary happens to come out identical: the acknowledgement names a revision, and an
    /// ack for revision 0 must not be allowed to stand in for revision 1's contents.
    ///
    /// `reported` is part of the fingerprint: "the endpoint now says no files changed" is a
    /// different report from "the endpoint never said", and Plan FE P0 exists because those two
    /// were once the same thing.
    var deliveryFingerprint: String {
        let parts: [String] = [
            String(reported.rawValue),
            filesCreated.joined(separator: "\u{2}"),
            filesModified.joined(separator: "\u{2}"),
            commandsRun.joined(separator: "\u{2}"),
            prURL ?? "",
            pushed ? "1" : "0",
            finalText ?? "",
            error ?? "",
        ]
        return parts.joined(separator: "\u{1}")
    }
}

// MARK: - What the wearer hears

/// The spoken and displayed wording around result delivery (Plan FE P4). Gathered in one place
/// because every line here is a claim about whether somebody heard something, and those are the
/// easiest claims in the app to overstate by accident.
enum AgentDeliveryPhrasing {

    /// Prefix for a replay of a result the wearer demonstrably did not get.
    static let missedPrefix = "Here's the result you missed. "

    /// Prefix for a replay of a result that was already read out in full. Not "you missed this":
    /// they didn't, they asked to hear it again.
    static let againPrefix = "Here it is again. "

    /// Prefix for a replay of a result whose delivery we cannot vouch for — the crash window.
    /// Deliberately hedged in both directions: it neither claims they heard it nor claims they
    /// didn't, because the record that would have said so never got written.
    static let ambiguousPrefix = "I may have already read you that result. "

    static let nothingToReplay = "There's no agent result to replay."

    /// After a relaunch the record survives but the words do not — deliberately, since persisting
    /// the agent's report of the wearer's work to close a rare edge is a worse trade than saying
    /// this. It hedges rather than claiming either way.
    static let ambiguousWithoutWords =
        "I may have already read you that result, but I no longer have the words to read it again."

    /// Status-line tail when the result finished but the wearer did not get it.
    static func statusTail(for state: AgentResultDelivery.State) -> String? {
        switch state {
        case .interrupted:
            return " I was cut off reading it — say replay to hear it again."
        case .suppressed:
            return " I couldn't read it out at the time — say replay to hear it."
        case .failed:
            return " I couldn't read it out — say replay to try again."
        case .pending, .playing, .completed:
            return nil
        }
    }

    /// Status-line tail when the record came back from a relaunch without ever reporting how
    /// playback ended.
    static let ambiguousTail = " I may have already read it to you — say replay to hear it again."
}
