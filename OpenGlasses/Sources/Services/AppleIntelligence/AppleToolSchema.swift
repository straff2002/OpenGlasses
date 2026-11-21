import Foundation

/// The Apple path's name for the shared on-device schema (Plan MQ P0).
///
/// The compact schema this file used to hold is now `OnDeviceToolSchema`, so Apple's on-device
/// model and the downloaded models describe a tool the same way. The Apple path reads it through
/// this alias and is unchanged: same type, same code, same output.
typealias AppleToolSchema = OnDeviceToolSchema

/// The arguments Apple's model produced for a tool call, read back into the dictionary every
/// `NativeTool.execute(args:)` takes. Pure.
enum AppleToolArguments {
    /// The JSON object as a dictionary, with explicit `null` values removed so an optional the
    /// model left out reads as absent — exactly as a cloud provider's call omits it — rather than
    /// as `NSNull` for a tool to trip over. Anything that is not a JSON object reads as no
    /// arguments.
    static func dictionary(fromJSON json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary.filter { !($0.value is NSNull) }
    }
}

/// How much of the app's conversation the on-device session is rebuilt with each turn, and how
/// that shrinks when the model reports its window is full (Plan JD P0). Pure.
///
/// The session is rebuilt from `conversationHistory` every turn rather than kept: the lean prompt
/// changes every turn (date, location, memory), and the app's history is the single record a
/// cleared or reloaded conversation already keeps consistent. Tool calls and their outputs are not
/// carried — the answer that followed them is.
enum AppleSessionPolicy {
    /// Turns (user and assistant entries) carried into a fresh session.
    static let carriedEntryLimit = 12

    /// The carry a turn starts with: what was asked for, but never more than the history holds.
    /// A brand-new conversation starts at 0, so a window that is full on the first attempt fails at
    /// once instead of "shortening" a history that was never there — a field report showed three
    /// rebuilt sessions (12, 4, 0) for a turn with nothing carried, each one re-running its tools.
    static func initialCarry(requested: Int, available: Int) -> Int {
        max(0, min(requested, available))
    }

    /// The next, smaller carry after the model refused the current one for size. `nil` when there
    /// is nothing left to drop: the prompt alone does not fit, which no retry can fix.
    static func carryAfterOverflow(_ current: Int) -> Int? {
        switch current {
        case ...0: return nil
        case 1...4: return 0
        default: return 4
        }
    }

    /// `carryAfterOverflow`, for a history of `available` entries: a shorter carry that would still
    /// hold every entry builds the same transcript, so it is skipped rather than retried.
    static func carryAfterOverflow(_ current: Int, available: Int) -> Int? {
        carryAfterOverflow(initialCarry(requested: current, available: available))
    }
}
