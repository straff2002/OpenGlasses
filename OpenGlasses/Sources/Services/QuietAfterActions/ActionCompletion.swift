import Foundation

/// Whether the thing a tool was asked to do is now true (Plan LA §1).
///
/// A tool's returned string is for the model. `ToolExecutionOutcome.completed` only says the tool
/// returned, not that the wearer's request landed: Spotify's search page opening, a route handed to
/// Maps and a Home Assistant call nobody confirmed all "complete". Only the tool knows the
/// difference, so it says so here, on the side, and the model's string is left alone.
///
/// No report means not done. That is the default for every tool that has not been reviewed, and
/// the only thing an MCP server's tool, a gateway call or a custom HTTP tool can ever give: their
/// behaviour is written elsewhere and cannot vouch for itself.
enum ActionCompletion: Equatable, Sendable {
    /// What was asked for has happened. `summary` is a few words for the phone and the trace
    /// ("Kitchen lights off", "Timer 10 minutes").
    case done(summary: String)
    /// Something happened, but not all of what was asked for, or not in a way anyone confirmed.
    case partial(reason: PartialReason)
    /// A question, a choice or a confirmation is still to come from the wearer.
    case awaitingWearer

    enum PartialReason: String, Equatable, Sendable {
        /// An app or a page was opened for the wearer to finish in (Spotify's search, Maps).
        case handedToApp
        /// What was asked for waits in a notification.
        case leftNotification
        /// Some of a batch went through and some did not.
        case someItemsFailed
        /// The request was sent and nothing confirmed that it took effect.
        case unverified
    }

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }

    /// The `done` summary, nil for anything else.
    var doneSummary: String? {
        if case .done(let summary) = self { return summary }
        return nil
    }

    /// A content-free token for the trace and the log.
    var token: String {
        switch self {
        case .done: return "done"
        case .partial(let reason): return "partial-\(reason.rawValue)"
        case .awaitingWearer: return "awaitingWearer"
        }
    }
}

/// The tools whose completion reports were reviewed (Plan LA §1, decision 2). A tool joins this
/// list in code review, and only here: `QuietTurnJudge` reads a `.done` from any other tool as not
/// done, and `ActionCompletionRosterTests` fails on a source file that records `.done` for a tool
/// that is not listed.
///
/// Never listed, whatever they report: anything that calls, messages or sends (decision 3 — "sent"
/// to the wrong person is the costliest silent mistake), first aid and emergency information,
/// anything that reads the camera, directions and navigation (they hand the route to Maps or a
/// notification), and every read-only tool.
enum QuietActionRoster {
    static let reviewed: Set<String> = [
        "set_timer",
        "set_alarm",
        "reminder",
        "flashlight",
        "brightness",
        "music_control",
        "home_assistant",
        "smart_home",
        "save_note",
        "save_location",
        "pomodoro",
    ]

    /// Never quiet, by decision, even if a later change gives them a report.
    static let neverQuiet: Set<String> = [
        "send_message", "send_via", "phone_call", "first_aid", "emergency_info",
        "navigate", "get_directions", "execute",
    ]

    static func isReviewed(_ tool: String) -> Bool {
        reviewed.contains(tool) && !neverQuiet.contains(tool)
    }
}

/// The side channel a native tool reports its `ActionCompletion` through (Plan LA P1).
///
/// `NativeToolRouter` opens a slot around each native tool's `execute` (`capture`), and only there:
/// an MCP server, the gateway and a custom HTTP tool run outside any such slot, so a report could
/// not land even if one tried. A tool calls `record(_:)`; the last report of the call wins, so a
/// tool that falls back to a weaker path can overwrite its own earlier `.done`.
///
/// The router hands a root call's report to whoever opened `collect` around it — the model turn's
/// tool dispatcher — and drops a composed child's, so a child's `.done` never stands for its parent.
@MainActor
enum ActionCompletionReport {

    /// One call's report, or the collector's view of one call.
    @MainActor
    final class Slot {
        /// Whether a tool's `record` may write here. False for the collector a caller opens: only
        /// the router's per-call slot accepts a tool's report.
        let acceptsToolRecords: Bool
        fileprivate(set) var completion: ActionCompletion?

        init(acceptsToolRecords: Bool) {
            self.acceptsToolRecords = acceptsToolRecords
        }
    }

    @TaskLocal static var slot: Slot?

    /// A tool reports how its call ended. Outside a native tool's call it does nothing.
    static func record(_ completion: ActionCompletion) {
        guard let slot, slot.acceptsToolRecords else { return }
        slot.completion = completion
    }

    /// The router's half: run one native tool's work in a fresh slot. A root call's report is
    /// passed to the enclosing collector, if there is one; a composed child's is dropped.
    static func capture<T>(isRoot: Bool, _ work: () async throws -> T) async rethrows -> T {
        let outer = slot
        let own = Slot(acceptsToolRecords: true)
        defer {
            if isRoot, let outer, !outer.acceptsToolRecords { outer.completion = own.completion }
        }
        return try await $slot.withValue(own) { try await work() }
    }

    /// The caller's half: run one call through the router and read the report its tool made.
    /// Nil when the tool made none, was not a native tool, or never ran.
    static func collect<T>(_ work: () async throws -> T) async rethrows -> (T, ActionCompletion?) {
        let collector = Slot(acceptsToolRecords: false)
        let value = try await $slot.withValue(collector) { try await work() }
        return (value, collector.completion)
    }
}
