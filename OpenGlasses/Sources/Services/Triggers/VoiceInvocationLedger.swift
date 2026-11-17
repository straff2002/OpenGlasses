import Foundation

/// A voice-invocation stream's error, in the app's own words (Plan JV P1). The SDK's
/// `VoiceInvocationError` is mapped onto it inside the flagged build; anything it adds later is
/// `.unknown`.
enum VoiceInvocationFailure: String, Equatable, CaseIterable {
    case deviceNotFound
    case invalidWearablesInterface
    case channelNotConnected
    case channelError
    case failToSendInitRequest
    case failToSendMessage
    case initRequestError
    case invalidActionMessageProto
    case unknownMessageType
    case actionFailed
    case invalidSessionState
    /// A request of a kind the app does not know (the SDK has only "launch" today).
    case unsupportedInvocation
    /// Thrown by something other than the stream's own error type.
    case unknown
}

/// The circumstances a request arrived in — the device questions the plan asks (does it reach a
/// backgrounded app with the phone locked?).
struct VoiceInvocationArrival: Equatable {
    enum RunState: String, Equatable { case active, inactive, background }
    var runState: RunState
    /// False while the phone is locked with data protection on.
    var protectedDataAvailable: Bool
}

/// What happened to each glasses' voice-invocation stream, kept for the support report (Plan JV
/// P1). Per device, the device known by the order it was first seen in, never by its identifier.
///
/// Field report the record is shaped around: opening the glasses mic over HFP can end DAT sessions.
/// An invocation starts listening, which may open that mic, so a link that drops (or a stream error
/// that arrives) after an invocation is recorded with how long after it came. Times are wall clock,
/// so the lines can be read beside the Display's availability lines in the same report.
@MainActor
final class VoiceInvocationLedger {
    static let shared = VoiceInvocationLedger()

    enum StopReason: String, Equatable {
        /// The device's link left `.connected`, or the device left the SDK's list.
        case linkDown
        /// The wearer's switch went off.
        case switchedOff
        /// The service shut down.
        case shutdown
    }

    enum Event: Equatable {
        case streamStarted
        case streamStartFailed(VoiceInvocationFailure)
        case streamStopped(StopReason, secondsSinceLastInvocation: Int?)
        case received(VoiceInvocationArrival)
        case answered(outcome: String, answer: VoiceInvocationAnswer, milliseconds: Int, delivered: Bool)
        /// The action finished after the deadline had already answered failure.
        case lateOutcome(outcome: String, success: Bool, milliseconds: Int)
        case error(VoiceInvocationFailure, secondsSinceLastInvocation: Int?)
    }

    struct Entry: Equatable {
        let at: Date
        let event: Event
    }

    /// Entries kept per device; the oldest go first.
    static let capacity = 40

    private(set) var devices: [String] = []
    private(set) var entries: [String: [Entry]] = [:]
    private var lastInvocation: [String: Date] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Seconds since the device's last request, if it had one.
    func secondsSinceLastInvocation(on device: String) -> Int? {
        lastInvocation[device].map { max(0, Int(now().timeIntervalSince($0).rounded())) }
    }

    func record(_ event: Event, device: String) {
        if !devices.contains(device) { devices.append(device) }
        let at = now()
        if case .received = event { lastInvocation[device] = at }
        var list = entries[device, default: []]
        list.append(Entry(at: at, event: event))
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        entries[device] = list
    }

    func reset() {
        devices = []
        entries = [:]
        lastInvocation = [:]
    }

    // MARK: - Report

    /// Empty when nothing was recorded — always, in a build without the feature.
    var reportLines: [String] {
        guard !devices.isEmpty else { return [] }
        let received = entries.values.joined().filter { if case .received = $0.event { return true }; return false }
        var lines = ["Voice invocations: \(received.count) received since launch"]
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        for (index, device) in devices.enumerated() {
            for entry in entries[device] ?? [] {
                lines.append("  glasses \(index + 1) · \(clock.string(from: entry.at)) · \(Self.describe(entry.event))")
            }
        }
        return lines
    }

    static func describe(_ event: Event) -> String {
        func since(_ seconds: Int?) -> String {
            seconds.map { ", \($0) s after the last invocation" } ?? ""
        }
        switch event {
        case .streamStarted:
            return "stream started"
        case .streamStartFailed(let failure):
            return "stream failed to start (\(failure.rawValue))"
        case .streamStopped(let reason, let seconds):
            return "stream stopped (\(reason.rawValue)\(since(seconds)))"
        case .received(let arrival):
            return "received (app \(arrival.runState.rawValue), phone \(arrival.protectedDataAvailable ? "unlocked" : "locked"))"
        case .answered(let outcome, let answer, let milliseconds, let delivered):
            let how = answer.success ? "success" : "failure (\(answer.refusal?.rawValue ?? "unknown"))"
            return "answered \(how) after \(milliseconds) ms, outcome \(outcome), \(delivered ? "delivered" : "not delivered")"
        case .lateOutcome(let outcome, let success, let milliseconds):
            return "finished after the deadline: outcome \(outcome), \(success ? "listening" : "not listening") after \(milliseconds) ms"
        case .error(let failure, let seconds):
            return "stream error \(failure.rawValue)\(since(seconds))"
        }
    }
}

extension VoiceInvocationOutcome {
    /// The outcome's case name, for the report and the log.
    var reportToken: String {
        switch self {
        case .run(.startListening): return "startListening"
        case .run(.interruptAndListen): return "interruptAndListen"
        case .alreadyListening: return "alreadyListening"
        case .refuse(let refusal): return "refused-\(refusal.rawValue)"
        }
    }
}
