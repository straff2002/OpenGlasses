#if DAT_EXPERIMENTAL
import Foundation

// Plan JV P1. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// The app side of a request: what it is doing, and the calls that act on a request.
@MainActor
protocol VoiceInvocationPerforming: AnyObject {
    func voiceInvocationContext() -> VoiceInvocationContext
    /// Runs the action and returns whether the app is listening for the wearer afterwards.
    func performVoiceInvocation(_ action: VoiceInvocationAction) async -> Bool
}

/// "Hey Meta, open Avenkin" (Plan JV P1): one voice-invocation stream per connected glasses, and an
/// answer to every request.
///
/// - **Streams follow the link.** `update(connectedDeviceIds:)` takes the devices whose link is
///   `.connected` (`GlassesConnectionService.connectedDeviceIds`) — never registration or the
///   device list. A device gets a stream when its link comes up and loses it when the link drops
///   or the device leaves the list; the wearer's switch off stops every stream.
/// - **Every request gets exactly one answer.** What it means is `VoiceInvocationResolver`'s call;
///   the answer goes back once the action has run, or as a failure at the deadline, whichever comes
///   first. A late result is recorded, not sent.
/// - **Everything is recorded** in `VoiceInvocationLedger` for the support report, and logged as
///   case names and numbers. The device is never named.
@MainActor
final class GlassesVoiceInvocationService {
    weak var performer: VoiceInvocationPerforming?

    private let source: VoiceInvocationSource
    private let ledger: VoiceInvocationLedger
    private let isEnabled: () -> Bool
    private let arrival: () -> VoiceInvocationArrival
    private let deadline: Duration

    private(set) var channels: [String: VoiceInvocationChannel] = [:]
    private var connected: [String] = []

    init(source: VoiceInvocationSource,
         ledger: VoiceInvocationLedger,
         deadline: Duration = VoiceInvocationResolver.answerDeadline,
         isEnabled: @escaping () -> Bool,
         arrival: @escaping () -> VoiceInvocationArrival) {
        self.source = source
        self.ledger = ledger
        self.deadline = deadline
        self.isEnabled = isEnabled
        self.arrival = arrival
    }

    /// The devices whose link is connected now.
    func update(connectedDeviceIds ids: [String]) {
        connected = ids
        reconcile()
    }

    /// The wearer's switch may have changed.
    func refresh() {
        reconcile()
    }

    /// Stop every stream.
    func shutdown() {
        for id in channels.keys.sorted() { stop(id, reason: .shutdown) }
        connected = []
    }

    private func reconcile() {
        let wanted = isEnabled() ? connected : []
        for id in channels.keys.sorted() where !wanted.contains(id) {
            stop(id, reason: connected.contains(id) ? .switchedOff : .linkDown)
        }
        for id in wanted where channels[id] == nil {
            open(id)
        }
    }

    private func open(_ id: String) {
        do {
            let channel = try source.openChannel(
                deviceId: id,
                onRequest: { [weak self] request in self?.handle(request, device: id) },
                onFailure: { [weak self] failure in self?.noteFailure(failure, device: id) })
            do {
                try channel.start()
            } catch {
                channel.stop()
                throw error
            }
            channels[id] = channel
            ledger.record(.streamStarted, device: id)
            PrivacyLog.device(.glasses, .voiceInvocationStream, state: PrivacyToken("started"))
        } catch {
            let failure = source.failure(for: error)
            ledger.record(.streamStartFailed(failure), device: id)
            PrivacyLog.device(.glasses, .voiceInvocationStream, state: PrivacyToken("startFailed"),
                              reason: PrivacyToken(failure.rawValue))
        }
    }

    private func stop(_ id: String, reason: VoiceInvocationLedger.StopReason) {
        guard let channel = channels.removeValue(forKey: id) else { return }
        channel.stop()
        // A link that drops soon after a request may be the glasses mic opening over HFP, which
        // is reported to end DAT sessions: the record says how long after.
        ledger.record(.streamStopped(reason, secondsSinceLastInvocation: ledger.secondsSinceLastInvocation(on: id)),
                      device: id)
        PrivacyLog.device(.glasses, .voiceInvocationStream, state: PrivacyToken("stopped"),
                          reason: PrivacyToken(reason.rawValue))
    }

    private func noteFailure(_ failure: VoiceInvocationFailure, device id: String) {
        ledger.record(.error(failure, secondsSinceLastInvocation: ledger.secondsSinceLastInvocation(on: id)),
                      device: id)
        PrivacyLog.device(.glasses, .voiceInvocationError, reason: PrivacyToken(failure.rawValue))
    }

    // MARK: - A request

    /// Answered once: the first of the action's result and the deadline wins.
    private final class Reply {
        var answered = false
    }

    private func handle(_ request: VoiceInvocationRequest, device id: String) {
        let arrived = arrival()
        ledger.record(.received(arrived), device: id)
        PrivacyLog.device(.glasses, .voiceInvocationReceived, state: PrivacyToken(arrived.runState.rawValue),
                          detail: PrivacyToken(arrived.protectedDataAvailable ? "unlocked" : "locked"))
        let reply = Reply()
        let begun = ContinuousClock.now
        let deadlineTask = Task { @MainActor [weak self, deadline] in
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            await self?.send(.failure(.timedOut), outcome: "timedOut", to: request, device: id,
                             reply: reply, begun: begun)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: VoiceInvocationOutcome
            var listening = false
            if let performer {
                outcome = VoiceInvocationResolver.resolve(performer.voiceInvocationContext(), enabled: isEnabled())
                if case .run(let action) = outcome {
                    listening = await performer.performVoiceInvocation(action)
                }
            } else {
                outcome = .refuse(.busy)
            }
            let answer = VoiceInvocationResolver.answer(for: outcome, started: listening)
            if reply.answered {
                // The deadline answered already; what the action came to is still worth knowing.
                ledger.record(.lateOutcome(outcome: outcome.reportToken, success: answer.success,
                                           milliseconds: Self.milliseconds(since: begun)), device: id)
                return
            }
            deadlineTask.cancel()
            await send(answer, outcome: outcome.reportToken, to: request, device: id, reply: reply, begun: begun)
        }
    }

    private func send(_ answer: VoiceInvocationAnswer, outcome: String, to request: VoiceInvocationRequest,
                      device id: String, reply: Reply, begun: ContinuousClock.Instant) async {
        guard !reply.answered else { return }
        reply.answered = true
        let milliseconds = Self.milliseconds(since: begun)
        let delivered = await request.respond(answer.success, answer.actionOutput)
        ledger.record(.answered(outcome: outcome, answer: answer, milliseconds: milliseconds, delivered: delivered),
                      device: id)
        PrivacyLog.device(.glasses, .voiceInvocationAnswered, state: PrivacyToken(outcome),
                          reason: answer.refusal.map { PrivacyToken($0.rawValue) },
                          count: milliseconds, success: answer.success)
    }

    private static func milliseconds(since begun: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - begun
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
#endif
