import Foundation

/// How one photo turn ended (Plan LT §3) — `AppState.capturePhotoAndSend` and
/// `captureAndAnalyzePhoto` return it.
///
/// The watch is the caller that needs it. Its photo commands used to await the turn and reply with
/// `appState.lastResponse`, which those functions leave untouched on every early return and every
/// failure, so a photo that could not be taken came back to the wrist as the previous answer. Every
/// other caller has a screen or the wearer's ear and ignores the result.
enum PhotoTurnResult: Equatable {
    /// The model answered about the photo; the answer.
    case answered(String)
    /// The selected model cannot see images.
    case cannotSee
    /// No glasses, and the caller asked for no phone camera.
    case glassesNotConnected
    /// No glasses, so the phone camera was opened to take the picture. Never a watch request's
    /// result: a watch request asks for no phone camera.
    case phoneCameraOpened
    /// The picture could not be taken.
    case captureFailed
    /// The picture was taken and no model answered about it.
    case modelFailed
    /// Another photo request is still running.
    case busy
}

/// What the watch is told about a photo command (Plan LT §3). Pure, so each result's reply is
/// pinned by `WatchPhotoReplyTests`.
///
/// `response` is sent only for an answer made by this request. Anything else is an `error` with a
/// short line, which the watch shows in place of an answer — never `lastResponse`, which belongs to
/// whatever turn last set it.
enum WatchPhotoReply {

    /// The command's reply.
    static func dictionary(for result: PhotoTurnResult) -> [String: Any] {
        if case .answered(let answer) = result {
            return ["status": "completed", "response": answer]
        }
        return ["status": "failed", "error": line(for: result) ?? ""]
    }

    /// The short line for a result that is not an answer; nil for an answer.
    static func line(for result: PhotoTurnResult) -> String? {
        switch result {
        case .answered:
            return nil
        case .cannotSee:
            return String(localized: "This model can't see pictures.")
        case .glassesNotConnected:
            return String(localized: "Glasses not connected.")
        case .phoneCameraOpened:
            return String(localized: "Take the photo on the phone.")
        case .captureFailed:
            return String(localized: "Couldn't take the photo.")
        case .modelFailed:
            return String(localized: "Took the photo, but couldn't get an answer.")
        case .busy:
            return String(localized: "Still working on the last one.")
        }
    }
}

/// One watch photo request at a time (Plan LT §3). A second one while the first runs is answered
/// `.busy` at once, rather than queued behind it to come back with the first one's answer.
struct WatchPhotoGate: Equatable {
    private(set) var inFlight = false

    /// Take the gate for a request. False — reply busy — when a watch photo request is already
    /// running, or the app is in the middle of another turn (`appBusy`).
    mutating func begin(appBusy: Bool) -> Bool {
        guard !inFlight, !appBusy else { return false }
        inFlight = true
        return true
    }

    mutating func end() { inFlight = false }
}
