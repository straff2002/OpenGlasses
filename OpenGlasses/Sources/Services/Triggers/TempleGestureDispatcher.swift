import Foundation

/// What the dispatcher needs from the app: the state a tap is resolved against, and the means to
/// carry it out. `AppState` conforms in production; tests use a recording fake.
@MainActor
protocol TempleActionPerforming: AnyObject {
    func templeContext() -> TempleContext
    func performTempleEffect(_ effect: TempleEffect) async
    func playTempleEarcon(_ earcon: TempleEarcon)
    /// Speak a short line — a refusal the wearer can act on, or a test-mode report.
    func announceTempleLine(_ line: String) async
}

/// Turns a decoded tap into something happening (Plan GJ P1): read the assignment, resolve it
/// against what the app is doing, confirm it with an earcon, then do it.
///
/// In test mode nothing runs; each tap is announced with the command it arrived as and what it is
/// assigned to — which is also how the calibration table gets checked on real glasses.
@MainActor
final class TempleGestureDispatcher: ObservableObject {

    struct Detection: Equatable {
        let gesture: TempleGesture
        let command: MediaRemoteCommand
        let action: TempleAction
        /// Nil in test mode, where nothing is resolved.
        let outcome: TempleOutcome?
        let at: Date
    }

    /// Announce taps instead of acting on them. Transient — Settings turns it on while its test
    /// screen is showing and off when it closes.
    @Published var testMode = false
    @Published private(set) var lastDetection: Detection?

    weak var performer: TempleActionPerforming?
    private let loadMap: () -> TempleGestureMap
    private let now: () -> Date

    init(performer: TempleActionPerforming? = nil,
         loadMap: @escaping () -> TempleGestureMap = { Config.templeGestureMap },
         now: @escaping () -> Date = Date.init) {
        self.performer = performer
        self.loadMap = loadMap
        self.now = now
    }

    /// Handle one tap. Returns the outcome it resolved to, or nil in test mode (or with no
    /// performer attached).
    @discardableResult
    func handle(_ gesture: TempleGesture, command: MediaRemoteCommand) async -> TempleOutcome? {
        guard let performer else { return nil }
        let action = loadMap().action(for: gesture)

        if testMode {
            lastDetection = Detection(gesture: gesture, command: command, action: action,
                                      outcome: nil, at: now())
            performer.playTempleEarcon(.accepted)
            await performer.announceTempleLine(Self.testLine(gesture: gesture, command: command,
                                                             action: action))
            return nil
        }

        let outcome = TempleActionResolver.resolve(action: action, context: performer.templeContext())
        lastDetection = Detection(gesture: gesture, command: command, action: action,
                                  outcome: outcome, at: now())
        PrivacyLog.device(.nowPlaying, .commandHandled, state: PrivacyToken(Self.logToken(outcome)),
                          command: PrivacyToken(gesture.rawValue))
        performer.playTempleEarcon(TempleEarcon.for(outcome))
        switch outcome {
        case .run(let effect):
            await performer.performTempleEffect(effect)
        case .ignored(let reason):
            if let line = reason.spokenLine {
                await performer.announceTempleLine(line)
            }
        }
        return outcome
    }

    /// What test mode says for a tap: the count, the raw command (so a wrong calibration is
    /// audible), and the current assignment.
    static func testLine(gesture: TempleGesture, command: MediaRemoteCommand,
                         action: TempleAction) -> String {
        let assigned = action == .nothing
            ? String(localized: "Not assigned.")
            : String(localized: "Assigned to \(action.displayName).")
        return String(localized: "\(gesture.displayName), \(command.spokenName). \(assigned)")
    }

    /// Log shape: the effect or refusal reason, never an id or anything the wearer said.
    static func logToken(_ outcome: TempleOutcome) -> String {
        switch outcome {
        case .ignored(let reason): return "ignored.\(reason.rawValue)"
        case .run(let effect):
            switch effect {
            case .startListening: return "startListening"
            case .interruptAndListen: return "interruptAndListen"
            case .endConversation: return "endConversation"
            case .endLiveSession: return "endLiveSession"
            case .setMicMuted(let muted): return muted ? "micMuted" : "micUnmuted"
            case .muteAndEndConversation: return "muteAndEndConversation"
            case .setLiveMicMuted(let muted): return muted ? "liveMicMuted" : "liveMicUnmuted"
            case .photoDescribe: return "photoDescribe"
            case .photoToCameraRoll: return "photoToCameraRoll"
            case .readDigest: return "readDigest"
            case .toggleRecording(let starting): return starting ? "recordingStarted" : "recordingStopped"
            case .askAgent: return "askAgent"
            case .musicPlayPause: return "musicPlayPause"
            case .quickAction: return "quickAction"
            }
        }
    }
}

extension MediaRemoteCommand {
    /// How test mode names the command a tap arrived as.
    var spokenName: String {
        switch self {
        case .togglePlayPause: return String(localized: "play-pause command")
        case .play: return String(localized: "play command")
        case .pause: return String(localized: "pause command")
        case .nextTrack: return String(localized: "next-track command")
        case .previousTrack: return String(localized: "previous-track command")
        }
    }
}
