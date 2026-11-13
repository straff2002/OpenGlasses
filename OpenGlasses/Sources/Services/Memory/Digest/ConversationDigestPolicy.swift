import Foundation

/// Plan LQ §5 — whether a note's model call is made now. Pure and table-tested, in the style of
/// `TimelinePassPolicy`: every refusal names itself, from a closed set that is safe to log.
///
/// In order:
/// 1. **No organisation profile pins it off** (`SettingKey.conversationDigestsEnabled`). Checked
///    first and named on its own, so a log reader can tell a company's choice from the wearer's.
/// 2. **The setting is on** (`Config.conversationDigestsEnabled`, default on, not behind Agent
///    Mode: decision 1).
/// 3. **HIPAA mode is off.** No note at all, on-device included.
/// 4. **A model is configured.**
/// 5. **The destination is the same**: the active provider answered the thread's last turn
///    (`ConversationThread.lastAnswerProvider`). Otherwise the words would go somewhere they never
///    went (decision 4).
/// 6. **An on-device model runs only in the foreground.** Backgrounded, the call is `deferred`,
///    which leaves the thread to the backlog. It is not a refusal (decision 3).
/// 7. **The store is open and writable, and the thread still exists.**
/// 8. **No call is running for the thread**, and it is not backing off (`TimelinePassBackoff`).
/// 9. **No spend cap is reached** (`TimelinePassPolicy.isAtSpendCap`). Never a cheaper model,
///    which would be a new destination. The backlog's daily cap is the backlog's, not a reason here.
enum ConversationDigestPolicy {

    enum SkipReason: String, Equatable, Sendable {
        case orgPinnedOff
        case settingOff
        case hipaaMode
        case noModel
        case providerChanged
        case storeUnavailable
        case threadGone
        case passRunning
        case backingOff
        case spendCap

        /// Whether the refusal is worth a privacy-log line. A switch the wearer or the company left
        /// off, a mode they chose and a missing model are states, not faults.
        var isWorthLogging: Bool {
            switch self {
            case .orgPinnedOff, .settingOff, .hipaaMode, .noModel:
                return false
            case .providerChanged, .storeUnavailable, .threadGone, .passRunning, .backingOff, .spendCap:
                return true
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case run
        /// An on-device model while the app is in the background: the backlog writes it later.
        case deferred
        case skip(SkipReason)

        var skipReason: SkipReason? {
            if case .skip(let reason) = self { return reason }
            return nil
        }
    }

    struct Conditions: Equatable, Sendable {
        var orgPinnedOff: Bool
        var enabled: Bool
        var hipaaMode: Bool
        /// The wearer's active provider, or nil when no model is configured.
        var provider: LLMProvider?
        /// The provider that answered the thread's last turn (`LLMProvider.rawValue`), or nil when
        /// none was recorded.
        var threadProvider: String?
        var inForeground: Bool
        var storeWritable: Bool
        var threadExists: Bool
        var passRunning: Bool
        var backingOff: Bool
        var atSpendCap: Bool
    }

    static func decide(_ conditions: Conditions) -> Outcome {
        guard !conditions.orgPinnedOff else { return .skip(.orgPinnedOff) }
        guard conditions.enabled else { return .skip(.settingOff) }
        guard !conditions.hipaaMode else { return .skip(.hipaaMode) }
        guard let provider = conditions.provider else { return .skip(.noModel) }
        // A thread that is gone has no provider to compare; it is named as gone below.
        guard !conditions.threadExists || conditions.threadProvider == provider.rawValue else {
            return .skip(.providerChanged)
        }
        if RelationEnrichmentPolicy.isOnDevice(provider), !conditions.inForeground { return .deferred }
        guard conditions.storeWritable else { return .skip(.storeUnavailable) }
        guard conditions.threadExists else { return .skip(.threadGone) }
        guard !conditions.passRunning else { return .skip(.passRunning) }
        guard !conditions.backingOff else { return .skip(.backingOff) }
        guard !conditions.atSpendCap else { return .skip(.spendCap) }
        return .run
    }
}
