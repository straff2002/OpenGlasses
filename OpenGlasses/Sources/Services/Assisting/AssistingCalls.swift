import Foundation

/// A call the expert's phone saw connect and end while a handover's clock ran (Plan KM P4).
/// Times only: `CXCallObserver` never says who was on the call, and nothing is recorded of it.
struct AssistingObservedCall: Codable, Equatable, Sendable {
    let connectedAt: Date
    let endedAt: Date

    var seconds: TimeInterval { max(0, endedAt.timeIntervalSince(connectedAt)) }
}

/// Which handover a call the expert's phone saw belongs to, and how long it ran (Plan KM P4).
/// Pure: every instant and every running clock is an argument.
///
/// **The call is the system's, and the app sees only that one happened.** `CXCallObserver` needs no
/// permission and reports a call's connect and end on this phone; the expert took it while they
/// had a handover open, so its minutes are the time reply's call minutes. Two rules keep the
/// figure honest:
/// - **One running clock, or none counted.** A call that connects while exactly one handover's
///   clock is running belongs to that handover. With none running, it was not for a job; with two
///   running, the app can't tell which job it was for, so it counts for neither rather than for
///   both.
/// - **Only a call seen to connect counts**, from its connect to its end. One that rang out, or
///   was first seen already ended, adds nothing.
///
/// What the app sees while it is suspended — a FaceTime call takes the screen — is a device check
/// (Plan KM P5). When it sees nothing, the reply carries no call minutes and says so, and the
/// technician's phone compares nothing rather than a guess.
struct AssistingCallTally: Equatable, Sendable {

    struct Completed: Equatable, Sendable {
        let handoverId: String
        let call: AssistingObservedCall
    }

    private struct Open: Equatable, Sendable {
        let handoverId: String
        let connectedAt: Date
    }

    private var open: [UUID: Open] = [:]
    /// Calls already decided (counted, or not for a job), so a repeat report changes nothing.
    private var settled: Set<UUID> = []

    init() {}

    /// Fold one report of a call in. `running` is the ids of the handovers whose clocks are running
    /// now. Returns the call it completed for a handover, if this report completed one.
    mutating func observe(_ call: ObservedCall, at now: Date, running: [String]) -> Completed? {
        guard !settled.contains(call.id) else { return nil }
        if call.hasConnected, open[call.id] == nil, !call.hasEnded {
            guard running.count == 1, let only = running.first else {
                settled.insert(call.id)
                return nil
            }
            open[call.id] = Open(handoverId: only, connectedAt: now)
            return nil
        }
        guard call.hasEnded else { return nil }
        settled.insert(call.id)
        guard let started = open.removeValue(forKey: call.id) else { return nil }
        return Completed(handoverId: started.handoverId,
                         call: AssistingObservedCall(connectedAt: started.connectedAt, endedAt: max(now, started.connectedAt)))
    }

    /// Calls connected and not yet ended.
    var openCalls: Int { open.count }
}
