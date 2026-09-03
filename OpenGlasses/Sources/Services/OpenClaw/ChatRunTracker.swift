import Foundation

// MARK: - chat event parsing

/// One `chat` event from the gateway, reduced to what a run watcher needs. The gateway streams
/// `state: "delta"` with the new `deltaText` and the authoritative buffered `message`, then one
/// terminal `final` / `aborted` / `error`, all keyed by `runId` and ordered by `seq`.
enum ChatRunEvent: Equatable {
    case delta(runId: String, seq: Int, bufferedText: String, replace: Bool)
    case final(runId: String, seq: Int, text: String)
    case aborted(runId: String, seq: Int, message: String?)
    case error(runId: String, seq: Int, message: String?)

    var runId: String {
        switch self {
        case .delta(let id, _, _, _), .final(let id, _, _), .aborted(let id, _, _), .error(let id, _, _):
            return id
        }
    }

    /// Parse a `chat` event payload. Nil for shapes that are not run updates.
    static func parse(payload: [String: Any]) -> ChatRunEvent? {
        guard let runId = payload["runId"] as? String, !runId.isEmpty,
              let state = payload["state"] as? String else { return nil }
        let seq = payload["seq"] as? Int ?? 0
        let text = messageText(payload["message"])
        switch state {
        case "delta":
            return .delta(runId: runId, seq: seq, bufferedText: text ?? "",
                          replace: payload["replace"] as? Bool ?? false)
        case "final":
            return .final(runId: runId, seq: seq, text: text ?? "")
        case "aborted":
            return .aborted(runId: runId, seq: seq, message: payload["errorMessage"] as? String)
        case "error":
            return .error(runId: runId, seq: seq, message: payload["errorMessage"] as? String)
        default:
            return nil
        }
    }

    /// Concatenate the text blocks of a gateway `message`.
    static func messageText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let content = message["content"] as? String { return content }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard (block["type"] as? String ?? "text") == "text" else { return nil }
            return block["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined()
    }
}

// MARK: - tracker

/// Correlates gateway chat replies with the requests that started them. A `sessions.send` or
/// `chat.send` answers with a `runId`; the reply arrives later on the same socket as `chat`
/// events. This tracker turns that into (a) streamed chunks for early speech, (b) an awaitable
/// terminal outcome per run, and (c) a *late* answer for a run whose waiter timed out — parked,
/// not dropped, because a question the wearer asked forty seconds ago is still owed an answer.
///
/// Pure with respect to time: the bridge owns the timeout clock and calls `park(runId:)`.
@MainActor
final class ChatRunTracker {

    enum Outcome: Equatable {
        case answered(String)
        case aborted(String?)
        case failed(String?)
        case timedOut
    }

    enum Update: Equatable {
        /// New spoken-safe text for a tracked run.
        case chunk(runId: String, text: String)
        /// A tracked run reached a terminal state while someone was waiting (or before anyone did).
        case completed(runId: String, outcome: Outcome)
        /// A run whose waiter had already given up produced its answer.
        case lateAnswer(runId: String, text: String)
        /// A chat event for a run this client never started (another client in the session).
        case unknownRun(runId: String)
    }

    /// Terminal-state snapshot the agent harness polls.
    struct RunState: Equatable {
        enum Phase: Equatable { case running, answered(String), aborted, failed(String?) }
        let phase: Phase
        var isTerminal: Bool { if case .running = phase { return false } else { return true } }
    }

    private struct Run {
        var bufferedText = ""
        var emittedCount = 0
        var continuation: CheckedContinuation<Outcome, Never>?
        var parked = false
        var terminal: RunState.Phase?
    }

    private var runs: [String: Run] = [:]
    private var order: [String] = []
    /// Terminal runs kept for harness polling before pruning.
    private let retainedRuns = 64

    // MARK: registration

    /// Start tracking a run before its reply can arrive.
    func register(runId: String) {
        guard runs[runId] == nil else { return }
        runs[runId] = Run()
        order.append(runId)
        prune()
    }

    var trackedRunIds: Set<String> { Set(runs.keys) }

    func state(runId: String) -> RunState? {
        guard let run = runs[runId] else { return nil }
        return RunState(phase: run.terminal ?? .running)
    }

    // MARK: waiting

    /// Suspend until the run reaches a terminal state or `park(runId:)` is called.
    func wait(runId: String) async -> Outcome {
        if let terminal = runs[runId]?.terminal { return Self.outcome(for: terminal) }
        register(runId: runId)
        return await withCheckedContinuation { continuation in
            runs[runId]?.continuation = continuation
        }
    }

    /// Give up waiting: the waiter gets `.timedOut`, the run stays tracked, and its eventual
    /// answer surfaces as `.lateAnswer`. Returns false when there was nothing to park.
    @discardableResult
    func park(runId: String) -> Bool {
        guard var run = runs[runId], run.terminal == nil else { return false }
        run.parked = true
        let continuation = run.continuation
        run.continuation = nil
        runs[runId] = run
        continuation?.resume(returning: .timedOut)
        return true
    }

    // MARK: events

    /// Feed one `chat` event payload. Returns what, if anything, the bridge should act on.
    func handle(payload: [String: Any]) -> Update? {
        guard let event = ChatRunEvent.parse(payload: payload) else { return nil }
        guard var run = runs[event.runId] else { return .unknownRun(runId: event.runId) }
        if run.terminal != nil { return nil }

        switch event {
        case .delta(_, _, let bufferedText, let replace):
            if replace { run.emittedCount = 0 }
            run.bufferedText = bufferedText
            let chunk = Self.nextSpeakableChunk(bufferedText: bufferedText, emitted: &run.emittedCount)
            runs[event.runId] = run
            return chunk.isEmpty ? nil : .chunk(runId: event.runId, text: chunk)

        case .final(_, _, let text):
            let clean = GatewaySpokenReplyControl.strip(text)
            run.terminal = .answered(clean)
            return finish(event.runId, run: run, outcome: .answered(clean), lateText: clean)

        case .aborted(_, _, let message):
            run.terminal = .aborted
            return finish(event.runId, run: run, outcome: .aborted(message), lateText: nil)

        case .error(_, _, let message):
            run.terminal = .failed(message)
            return finish(event.runId, run: run, outcome: .failed(message), lateText: nil)
        }
    }

    // MARK: - private

    private func finish(_ runId: String, run: Run, outcome: Outcome, lateText: String?) -> Update? {
        var run = run
        let continuation = run.continuation
        run.continuation = nil
        let wasParked = run.parked
        runs[runId] = run
        if let continuation {
            continuation.resume(returning: outcome)
            return .completed(runId: runId, outcome: outcome)
        }
        if wasParked, let lateText, !lateText.isEmpty {
            return .lateAnswer(runId: runId, text: lateText)
        }
        return .completed(runId: runId, outcome: outcome)
    }

    /// The portion of the sanitized buffered text not yet emitted. Text that may still be an
    /// unfinished spoken-reply control line is withheld until its line break arrives.
    private static func nextSpeakableChunk(bufferedText: String, emitted: inout Int) -> String {
        if GatewaySpokenReplyControl.isPossiblyUnfinishedControlLine(bufferedText) { return "" }
        let clean = GatewaySpokenReplyControl.strip(bufferedText)
        guard clean.count > emitted else { return "" }
        let chunk = String(clean.dropFirst(emitted))
        emitted = clean.count
        return chunk
    }

    private static func outcome(for phase: RunState.Phase) -> Outcome {
        switch phase {
        case .running: return .timedOut
        case .answered(let text): return .answered(text)
        case .aborted: return .aborted(nil)
        case .failed(let message): return .failed(message)
        }
    }

    private func prune() {
        while order.count > retainedRuns {
            // Drop the oldest *terminal* run; never evict one still awaited.
            guard let victim = order.first(where: { runs[$0]?.terminal != nil && runs[$0]?.continuation == nil }) else { return }
            order.removeAll { $0 == victim }
            runs[victim] = nil
        }
    }
}
