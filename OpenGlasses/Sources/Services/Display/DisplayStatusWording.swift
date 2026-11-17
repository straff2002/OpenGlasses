import Foundation

/// The in-lens Display's state, as `device_info` reads it, so the assistant can answer "is the
/// display / HUD connected?" from a reading instead of saying it cannot tell.
///
/// State only: whether glasses are connected, whether they have a display, whether the HUD switch
/// is on, whose the lens is, and how the last send ended. Nothing about what was, or was not,
/// shown — no text, no page, no picture.
///
/// **Inputs.** `glassesPhase` is `GlassesConnectionService.phase` (via `AppState.glassesPhase`):
/// connected means `linkState == .connected`, never registration or the device list.
/// `hasDisplay` is `GlassesDisplayService.deviceSupportsDisplay()`; `availability` its reading now
/// (`practiceAvailability`); `worn` `GlassesConnectionService.isWorn`. SDK-free, so the wording
/// and its tests run headless.
///
/// **Backends.** The Meta Ray-Ban Display rides the DAT link, so its connection is the glasses'
/// phase. EVEN G2 is a separate Bluetooth pair that connects when something is sent: the app knows
/// it is paired, and only the last send says whether it was reached.
struct DisplayStatusReading: Equatable {
    enum Backend: Equatable { case metaDisplay, evenG2 }

    var backend: Backend = .metaDisplay
    var glassesPhase: GlassesConnectionPhase = .noGlassesAdded
    var hasDisplay = false
    var hudEnabled = false
    var availability: DisplayAvailability = .off
    var worn: Bool?
    /// The glasses ended our display session (the Back gesture, a temple tap): the wearer closed it.
    var dismissedByWearer = false
    var lastSend: HUDSendRecord?
}

/// The words `device_info` returns about the Display. Plain sentences without a closing full stop
/// (the tool joins them); no SDK case names.
enum DisplayStatusWording {
    static func lines(_ reading: DisplayStatusReading) -> [String] {
        switch reading.backend {
        case .metaDisplay: return metaLines(reading)
        case .evenG2: return evenLines(reading)
        }
    }

    private static func metaLines(_ r: DisplayStatusReading) -> [String] {
        switch r.glassesPhase {
        case .noGlassesAdded:
            return ["No glasses are added, so there is no in-lens display to use"]
        case .addedDisconnected:
            return ["The glasses aren't connected, so the in-lens display isn't available"]
        case .connecting:
            return ["The glasses are still connecting, so the in-lens display isn't available yet"]
        case .connected:
            break
        }
        guard r.hasDisplay else {
            return ["The connected glasses don't have an in-lens display"]
        }
        var lines = ["Display glasses are connected"]
        guard r.hudEnabled else {
            lines.append(switchedOff)
            return lines
        }
        switch r.availability {
        case .inUse:
            lines.append("Another app is using the display right now, so nothing from this app shows on it until that app is done")
            return lines
        case .off:
            lines.append(r.worn == false
                         ? "The display is off because the glasses read as not being worn"
                         : "The display is off right now")
            return lines
        case .ours:
            lines.append(r.dismissedByWearer
                         ? "The display is on, but the wearer closed it on the glasses; it opens again with the next answer or anything opened on it"
                         : "The display is on and ready to show things")
        }
        lines.append(lastSendLine(r.lastSend))
        return lines
    }

    private static func evenLines(_ r: DisplayStatusReading) -> [String] {
        guard r.hasDisplay else {
            return ["The in-lens display is set to EVEN G2, but no EVEN G2 glasses are paired"]
        }
        var lines = ["The in-lens display is EVEN G2 glasses, which are paired; they connect when something is sent"]
        guard r.hudEnabled else {
            lines.append(switchedOff)
            return lines
        }
        lines.append(r.dismissedByWearer
                     ? "The display is on, but the wearer closed it on the glasses"
                     : "The display is on")
        lines.append(lastSendLine(r.lastSend))
        return lines
    }

    private static let switchedOff = "The display (HUD) is switched off in Settings, so nothing is shown on the lens"

    /// How the last send ended. `sent` means the glasses took it: not proof it was drawn (Display
    /// Recording blanks third-party content while a send still succeeds), so the words say
    /// "reached", never "is showing".
    static func lastSendLine(_ record: HUDSendRecord?) -> String {
        guard let record else { return "Nothing has been sent to the display since the app started" }
        let what = noun(record.kind)
        switch record.outcome {
        case .sent:
            return "The last thing sent to the display (\(what)) reached the glasses"
        case .failed:
            return "The last thing sent to the display (\(what)) failed to reach the glasses"
        case .timedOut:
            return "The last thing sent to the display (\(what)) timed out without reaching the glasses"
        case .retriedWithoutPicture:
            return "The last picture sent to the display failed, so it was sent again as text only"
        }
    }

    private static func noun(_ kind: HUDSendRecord.Kind) -> String {
        switch kind {
        case .text: return "text"
        case .screen: return "a card"
        case .picture: return "a picture"
        case .clear: return "clearing the lens"
        case .video: return "a video"
        }
    }
}
