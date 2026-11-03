import Foundation

/// Plan KK P2 — whether the summary pass runs after a reply. Pure and table-tested, in the style
/// of `RelationEnrichmentPolicy`: every refusal names itself, from a closed set that is safe to log.
///
/// The pass sends the wearer's earlier words to the model answering the conversation, so it runs
/// only when that is the same destination they already went to, the wearer has not turned it off,
/// and nothing about the moment makes a write unsafe:
///
/// 1. **The setting is on** (`Config.conversationTimelineEnabled`, default on, not behind Agent
///    Mode: owner decision 1).
/// 2. **HIPAA mode is off** (decision 3). A medical summary needs its own review, and a local-only
///    pass cannot run in the background.
/// 3. **A model is configured, and it is not on the phone.** The request budget the timeline
///    serves is a cloud thing, and on-device inference cannot run backgrounded.
/// 4. **The turn built a cloud request** whose counts the pass can read. A turn answered on the
///    phone, or by a path that never budgeted a request, leaves nothing to count from.
/// 5. **The conversation store is open** (not locked, not after a failed read), and the thread
///    answered is still the active one, which is the conversation the in-memory history holds.
/// 6. **No pass is already running for this thread**, and the thread is not backing off after a
///    failure.
/// 7. **The spend caps are not reached.** A background pass never asks to go past a cap.
enum TimelinePassPolicy {

    enum SkipReason: String, Equatable, Sendable {
        case settingOff
        case hipaaMode
        case noModel
        case onDeviceModel
        case noRequestReading
        case storeUnavailable
        case threadNotActive
        case passRunning
        case backingOff
        case spendCap
        /// Everything that has left the request is already covered, and no merge is due.
        case nothingEligible

        /// Whether the refusal is worth a privacy-log line. A switch the wearer left off, a mode
        /// they chose, a phone model and the ordinary short conversation are states, not faults,
        /// and a line per turn for them is noise. The rest are a pass that wanted to run and could
        /// not, which is what a log reader needs to tell a quiet feature from a broken one.
        var isWorthLogging: Bool {
            switch self {
            case .settingOff, .hipaaMode, .noModel, .onDeviceModel, .noRequestReading, .nothingEligible:
                return false
            case .storeUnavailable, .threadNotActive, .passRunning, .backingOff, .spendCap:
                return true
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case run
        case skip(SkipReason)

        var skipReason: SkipReason? {
            if case .skip(let reason) = self { return reason }
            return nil
        }
    }

    struct Conditions: Equatable, Sendable {
        var enabled: Bool
        var hipaaMode: Bool
        /// The wearer's active provider, or nil when no model is configured.
        var provider: LLMProvider?
        var hasRequestReading: Bool
        var storeWritable: Bool
        var threadIsActive: Bool
        var passRunning: Bool
        var backingOff: Bool
        var atSpendCap: Bool
    }

    /// The conditions in the order that gives each its own reason.
    static func decide(_ conditions: Conditions) -> Outcome {
        guard conditions.enabled else { return .skip(.settingOff) }
        guard !conditions.hipaaMode else { return .skip(.hipaaMode) }
        guard let provider = conditions.provider else { return .skip(.noModel) }
        guard !RelationEnrichmentPolicy.isOnDevice(provider) else { return .skip(.onDeviceModel) }
        guard conditions.hasRequestReading else { return .skip(.noRequestReading) }
        guard conditions.storeWritable else { return .skip(.storeUnavailable) }
        guard conditions.threadIsActive else { return .skip(.threadNotActive) }
        guard !conditions.passRunning else { return .skip(.passRunning) }
        guard !conditions.backingOff else { return .skip(.backingOff) }
        guard !conditions.atSpendCap else { return .skip(.spendCap) }
        return .run
    }

    /// Whether a cap is reached for the pass. Stricter than a wearer's turn: a turn at the cap is
    /// asked about (or moved to a cheaper model), and the wearer may agree to go past for the day
    /// or month; the pass is never asked about, so a reached cap stops it whatever was agreed,
    /// and it never moves to a cheaper model, which would be a new destination. A cap that cannot
    /// be counted for this model does not stop it, as it does not stop the wearer's turns.
    static func isAtSpendCap(_ decision: SpendCapPolicy.Decision) -> Bool {
        switch decision {
        case .confirmToContinue, .fallBackToCheaperModel: return true
        case .ok, .warn, .notEnforceable: return false
        }
    }
}

/// Plan KK P2 — per-thread backoff after a failed summary. Pure.
///
/// A failure (an error, a refusal, a summary the acceptance policy turned down) leaves the range
/// uncovered and costs the wearer nothing at once, but retrying on every reply would spend on a
/// model that keeps failing. So after the n-th failure in a row the next 2^(n-1) passes are
/// skipped, up to `maximumSkip`, and a success clears it.
struct TimelinePassBackoff: Equatable, Sendable {
    static let maximumSkip = 8

    private(set) var failures = 0
    private(set) var passesToSkip = 0

    /// Whether this pass is skipped; counts the skip when it is.
    mutating func shouldSkip() -> Bool {
        guard passesToSkip > 0 else { return false }
        passesToSkip -= 1
        return true
    }

    mutating func recordFailure() {
        failures += 1
        passesToSkip = min(Self.maximumSkip, 1 << min(failures - 1, 10))
    }

    mutating func recordSuccess() {
        failures = 0
        passesToSkip = 0
    }
}
