import AVFoundation
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// The mechanism that actually holds / drops the Now Playing claim. Split behind a protocol so
/// `MediaTriggerService`'s state machine is testable with a spy — the production claimer touches
/// `AVAudioPlayer` + `MPRemoteCommandCenter`, which have no headless seam.
@MainActor
protocol NowPlayingClaiming: AnyObject {
    /// Begin holding Now Playing in `mode`: register remote-command handlers and, for `.standby`
    /// only, start silent playback. Temple-gesture commands are delivered to `onCommand` until
    /// `release()`.
    func claim(mode: NowPlayingClaimMode, onCommand: @escaping (MediaRemoteCommand) -> Void)
    /// Drop the claim: stop playback, unregister handlers, clear our Now Playing info.
    func release()
    /// Whether the standby claim's silent player is playing, or about to start. False with no
    /// standby claim. iOS can stop the player under us without a word to the claim, and a standby
    /// claim with no audio running is not one, so the service takes the claim afresh when it
    /// reads false.
    var standbyClaimLive: Bool { get }
    /// The shared audio session's shape as a log token (`playAndRecord-mixable`): what iOS weighs
    /// when it picks the Now Playing app, so the support log can say what the claim was up against.
    var sessionShape: String { get }
}

/// What asked for a look at the claim, as written to the support log.
enum ClaimRecheckCause: String {
    /// An audio-session or lifecycle notification, or a change in the conversation's state.
    case inputsChanged
    /// A tap's action has finished. Actions reshape the shared session (the wake word
    /// reconfigures for a photo, a reply is spoken), and that is when the claim was seen to die.
    case tapAction
    /// A conversation's hand-back was deferred because a rider is on the session, so the session
    /// was reconfigured in place under the claim's player.
    case handBackDeferred
    /// The glasses connected, disconnected, or went on or off the wearer's face.
    case glassesChanged
}

/// Temple taps (Plans CH + GJ): claims Now Playing so the glasses' temple gestures (standard AVRCP
/// media commands) reach us, decodes them into one, two or three taps, and hands each tap to
/// `onGesture` — no wake word, no phone touch.
///
/// The claim is governed entirely by the pure `MediaTriggerPolicy`: a silent-player standby claim
/// when nothing else is going on, handlers-only session control while our own conversation holds
/// the audio session, and nothing while the glasses are away or off the face, while the user's
/// audio plays or another person is on the line. iOS shows whoever holds Now Playing on the lock
/// screen, so once the user's media has played the claim stays with their player — paused or
/// not — until the glasses are next put on or reconnect.
/// What a tap *does* is not decided here — `TempleActionResolver` does that with the conversation
/// state in hand, which is why there is no suppression flag any more: "already listening" is an
/// answer the resolver gives, not a reason to drop the tap.
///
/// A standby claim is only as good as its silent player, and iOS stops that player without telling
/// us — a tester's Gen 2 heard the first tap after launch and nothing after the wake word
/// reconfigured the session for it. So the policy reads the player's health, a dead standby claim
/// is taken afresh, and the claim is looked at again after every tap's action and every deferred
/// hand-back. Every release says which condition won and every unheard command why.
///
/// All inputs are injected closures and the claimer is a protocol, so every state transition is
/// drivable headlessly; only `SilentNowPlayingClaimer` needs a device (GJ P2).
@MainActor
final class MediaTriggerService {

    /// Fired for each decoded tap, with the command it arrived as (test mode announces both).
    var onGesture: ((TempleGesture, MediaRemoteCommand) -> Void)?

    /// Whether a realtime voice session (Gemini Live / OpenAI Realtime) is running.
    var realtimeSessionActive: () -> Bool = { false }

    /// Whether a Direct-mode conversation is under way.
    var conversationActive: () -> Bool = { false }

    /// Whether the glasses are connected and not known to be off the wearer's face. The app calls
    /// `evaluate(cause: .glassesChanged)` when either reading changes.
    var glassesPresent: () -> Bool = { false }

    /// Posted (by `MusicControlTool`) just before a command is issued to the *user's* player,
    /// so we stand down pre-emptively instead of racing their playback for Now Playing.
    static let userPlaybackRequested = Notification.Name("MediaTriggerUserPlaybackRequested")

    private let isEnabled: () -> Bool
    private let isOtherAudioPlaying: () -> Bool
    private let leaseOwner: () -> AudioSessionOwner?
    private let calibration: () -> TempleCalibration
    private let claimer: NowPlayingClaiming
    private let clock: () -> TimeInterval
    private var gate: TriggerGate
    private var decoder: TempleGestureDecoder

    private(set) var claimedMode: NowPlayingClaimMode?
    var isClaimed: Bool { claimedMode != nil }
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var settleRecheck: Task<Void, Never>?
    private let sleep: (TimeInterval) async -> Void
    private let settleDelay: TimeInterval
    private let reclaimCooldown: TimeInterval
    private var lastClaimAt: TimeInterval?
    /// The user's media has played since the glasses last arrived, so their player keeps Now
    /// Playing. Cleared when the glasses arrive (connect, or go back on the face).
    private(set) var yieldedToMedia = false
    /// The glasses reading at the last evaluation, so an arrival can be told from a steady state.
    private var lastGlassesPresent = false

    /// - Parameters:
    ///   - debounceInterval: a second tap inside this window of the last one that fired is
    ///     dropped — a fumble while adjusting the glasses, not a new instruction.
    ///   - settleDelay: how long after a tap's action (or a deferred hand-back) the claim is
    ///     looked at a second time, once the session reshaping it set off has run.
    ///   - reclaimCooldown: a standby claim found dead within this long of being taken is not
    ///     taken again yet, so a player that will not stay up is not restarted on every
    ///     notification.
    ///   - sleep: the delay behind the settle re-check (a test drives it).
    init(claimer: NowPlayingClaiming? = nil,
         isEnabled: @escaping () -> Bool = { Config.mediaTriggerEnabled },
         isOtherAudioPlaying: @escaping () -> Bool = { AVAudioSession.sharedInstance().isOtherAudioPlaying },
         leaseOwner: @escaping () -> AudioSessionOwner? = { AudioSessionCoordinator.shared.currentOwner },
         calibration: @escaping () -> TempleCalibration = { TempleCalibration.current },
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         debounceInterval: TimeInterval = 1.0,
         settleDelay: TimeInterval = 2.0,
         reclaimCooldown: TimeInterval = 2.0,
         sleep: @escaping (TimeInterval) async -> Void = { seconds in
             try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
         }) {
        self.claimer = claimer ?? SilentNowPlayingClaimer()
        self.isEnabled = isEnabled
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.leaseOwner = leaseOwner
        self.calibration = calibration
        self.clock = clock
        self.gate = TriggerGate(debounceInterval: debounceInterval, minimumConfidence: 1.0)
        self.decoder = TempleGestureDecoder(calibration: calibration())
        self.settleDelay = settleDelay
        self.reclaimCooldown = reclaimCooldown
        self.sleep = sleep
    }

    // MARK: - Policy application (tested)

    /// Re-run the claim/release policy against the live inputs and apply the decision. A standby
    /// claim whose silent player has stopped counts as no claim, so it is taken afresh.
    func evaluate(cause: ClaimRecheckCause = .inputsChanged) {
        let glassesHere = glassesPresent()
        if glassesHere && !lastGlassesPresent { yieldedToMedia = false }
        lastGlassesPresent = glassesHere
        let userAudio = isOtherAudioPlaying()
        if userAudio { yieldedToMedia = true }
        let conditions = MediaTriggerConditions(
            triggerEnabled: isRunning && isEnabled(),
            glassesPresent: glassesHere,
            userAudioPlaying: userAudio,
            yieldedToMedia: yieldedToMedia,
            realtimeSessionActive: realtimeSessionActive(),
            leaseOwner: leaseOwner(),
            claimedMode: claimedMode,
            conversationActive: conversationActive(),
            sessionControlEnabled: calibration().sessionControlAvailable,
            standbyClaimLive: claimedMode == .standby ? claimer.standbyClaimLive : true)
        if conditions.effectiveClaimedMode != conditions.claimedMode {
            PrivacyLog.device(.nowPlaying, .claimLapsed,
                              state: PrivacyToken(NowPlayingClaimMode.standby.rawValue),
                              reason: PrivacyToken(cause.rawValue),
                              detail: PrivacyToken(claimer.sessionShape))
            if let last = lastClaimAt, clock() - last < reclaimCooldown,
               MediaTriggerPolicy.desiredMode(conditions) == .standby {
                return
            }
        }
        switch MediaTriggerPolicy.decide(conditions) {
        case .claim(let mode):
            // A mode switch is a release and a fresh claim: the standby player must stop before a
            // conversation's audio runs, and must only start again once the conversation is over.
            // A lapsed standby claim is released the same way, so its handlers are not doubled.
            if claimedMode != nil { claimer.release() }
            takeClaim(mode)
        case .release:
            releaseClaim(reason: MediaTriggerPolicy.releaseReason(conditions)?.rawValue ?? "lapsed")
        case .defer:
            break
        }
    }

    /// Look at the claim after something that may have reshaped the shared session under it:
    /// now, and once more after `settleDelay`, because the reshaping (the wake word reconfiguring
    /// for a tap's photo, say) runs a moment after the action that set it off. A live claim is
    /// logged with the session's shape, so a tap that then goes unheard can be read against it.
    func recheckClaim(after cause: ClaimRecheckCause) {
        guard isRunning else { return }
        recheckNow(cause)
        settleRecheck?.cancel()
        let sleep = self.sleep, delay = settleDelay
        settleRecheck = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.settleRecheck = nil
            guard self.isRunning else { return }
            self.recheckNow(cause)
        }
    }

    /// Feed a temple-gesture command. Fires `onGesture` iff the claim is live, the command decodes
    /// to a tap (not coalesced into the previous one, known to the calibration table) and the
    /// debounce passes. Returns the gesture that fired, if any. A command that fires nothing is
    /// logged with why, so "the tap did nothing" can be told apart from "no tap arrived".
    @discardableResult
    func handleRemoteCommand(_ command: MediaRemoteCommand) -> TempleGesture? {
        guard isClaimed else { return drop(command, "notClaimed") }
        guard isEnabled() else { return drop(command, "disabled") }
        let now = clock()
        guard let gesture = decoder.decode(command, at: now) else {
            return drop(command, decoder.calibration.gesture(for: command) == nil ? "unmapped" : "coalesced")
        }
        guard gate.shouldFire(at: now, confidence: 1.0, suppressed: false) else {
            return drop(command, "debounced")
        }
        PrivacyLog.device(.nowPlaying, .commandReceived, state: PrivacyToken(gesture.rawValue),
                          command: PrivacyToken(command.rawValue))
        onGesture?(gesture, command)
        return gesture
    }

    /// Stand down *before* the user's playback starts (a `MusicControlTool` command is on its
    /// way to their player): release now so we never race them for Now Playing, and leave it with
    /// their player — as with any media of theirs — until the glasses next arrive.
    func standDownForUserPlayback() {
        yieldedToMedia = true
        releaseClaim(reason: "userPlaybackRequested")
    }

    // MARK: - Lifecycle

    /// Start observing the audio environment and apply the policy. Idempotent; no-op unless the
    /// setting is enabled.
    func start() {
        guard !isRunning, isEnabled() else { return }
        isRunning = true
        let center = NotificationCenter.default
        let reevaluate: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // Every signal that the audio world changed funnels into one re-evaluation; the policy
        // reads live inputs, so the observer doesn't need to interpret the notification.
        var names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.silenceSecondaryAudioHintNotification,
            AVAudioSession.routeChangeNotification,
        ]
        #if canImport(UIKit)
        names.append(UIApplication.didBecomeActiveNotification)
        #endif
        observers = names.map { center.addObserver(forName: $0, object: nil, queue: .main, using: reevaluate) }
        observers.append(center.addObserver(
            forName: Self.userPlaybackRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.standDownForUserPlayback() }
        })
        observers.append(center.addObserver(
            forName: AudioSessionCoordinator.riderHandBackDeferred, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckClaim(after: .handBackDeferred) }
        })
        evaluate()
    }

    /// Stop observing and drop any claim.
    func stop() {
        isRunning = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        settleRecheck?.cancel()
        settleRecheck = nil
        releaseClaim(reason: "stopped")
    }

    /// Re-apply the setting (call when the user toggles it in Settings). Switching it on is a
    /// fresh start, so a yield to the user's media is forgotten.
    func refresh() {
        stop()
        yieldedToMedia = false
        gate.reset()
        decoder = TempleGestureDecoder(calibration: calibration())
        start()
    }

    // MARK: - Private

    private func takeClaim(_ mode: NowPlayingClaimMode) {
        claimedMode = mode
        lastClaimAt = clock()
        claimer.claim(mode: mode) { [weak self] command in
            self?.handleRemoteCommand(command)
        }
        PrivacyLog.device(.nowPlaying, .claimed, state: PrivacyToken(mode.rawValue),
                          detail: PrivacyToken(claimer.sessionShape))
    }

    /// `reason` is the condition that won (`MediaTriggerReleaseReason`), `userPlaybackRequested`
    /// or `stopped`.
    private func releaseClaim(reason: String) {
        guard isClaimed else { return }
        claimedMode = nil
        claimer.release()
        PrivacyLog.device(.nowPlaying, .released, state: PrivacyToken(reason))
    }

    private func recheckNow(_ cause: ClaimRecheckCause) {
        let wasLive = claimedMode == .standby && claimer.standbyClaimLive
        evaluate(cause: cause)
        if wasLive, claimedMode == .standby {
            PrivacyLog.device(.nowPlaying, .claimChecked, state: PrivacyToken("live"),
                              reason: PrivacyToken(cause.rawValue),
                              detail: PrivacyToken(claimer.sessionShape))
        }
    }

    private func drop(_ command: MediaRemoteCommand, _ reason: String) -> TempleGesture? {
        PrivacyLog.device(.nowPlaying, .commandDropped, state: PrivacyToken(reason),
                          command: PrivacyToken(command.rawValue))
        return nil
    }
}

// MARK: - Production claimer (device runtime)

/// Holds Now Playing the standard way: `MPRemoteCommandCenter` handlers plus, in `.standby`, a
/// silent looping zero-volume `AVAudioPlayer` on the shared audio session. The standby player is
/// registered with the Plan AS coordinator as a *coexisting* rider — it lives under the wake-word
/// listener's session and must never preempt or deactivate it.
///
/// `.sessionControl` touches the audio session not at all: no player, no activation, no ledger
/// entry. The conversation that owns the session (and its interruption / resume handling, Plans
/// AO/AP) is left exactly as it was; the handlers are just not taken away from under it.
///
/// Device-pending (Plan GJ P2, formerly CH P3): whether iOS keeps Now Playing with a
/// `mixWithOthers` session, and whether it routes the commands to a record-and-play conversation,
/// can only be confirmed on hardware; `sessionShape` puts the session's shape beside every claim
/// in the support log so the next report can say. Which temple gestures arrive as which commands
/// is confirmed on a Ray-Ban Meta Gen 2 (`TempleCalibration`).
@MainActor
final class SilentNowPlayingClaimer: NowPlayingClaiming {

    /// What we publish while holding the claim: a playback rate and nothing to read. iOS still
    /// draws its Now Playing widget for the claim, but with no title of ours on the lock screen.
    nonisolated static let claimInfo: [String: Any] = [MPNowPlayingInfoPropertyPlaybackRate: 1.0]

    /// Whether a Now Playing info dictionary is our own claim rather than real user media: it has
    /// no title and no artist. `NowPlayingSnapshot` (the "what's playing?" reader) skips it.
    nonisolated static func isOwnInfo(_ info: [String: Any]) -> Bool {
        info[MPMediaItemPropertyTitle] == nil && info[MPMediaItemPropertyArtist] == nil
    }

    private var player: AVAudioPlayer?
    /// The silent loop is waiting for the session to activate before it starts.
    private var playPending = false
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var coexistToken: UUID?

    var standbyClaimLive: Bool {
        guard let player else { return false }
        return playPending || player.isPlaying
    }

    var sessionShape: String {
        let session = AVAudioSession.sharedInstance()
        return Self.shapeToken(category: session.category, options: session.categoryOptions)
    }

    /// `playAndRecord-mixable`: the category's short name and whether it mixes with others. iOS
    /// does not give Now Playing to an app whose session mixes, which is the first thing to rule
    /// in or out when a claim that looks live hears no taps.
    nonisolated static func shapeToken(category: AVAudioSession.Category,
                                       options: AVAudioSession.CategoryOptions) -> String {
        let name: String
        switch category {
        case .playAndRecord: name = "playAndRecord"
        case .playback: name = "playback"
        case .ambient: name = "ambient"
        case .soloAmbient: name = "soloAmbient"
        case .record: name = "record"
        case .multiRoute: name = "multiRoute"
        default: name = "other"
        }
        return name + (options.contains(.mixWithOthers) ? "-mixable" : "-exclusive")
    }

    func claim(mode: NowPlayingClaimMode, onCommand: @escaping (MediaRemoteCommand) -> Void) {
        guard commandTargets.isEmpty, player == nil else { return }

        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, as mapped: MediaRemoteCommand) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in onCommand(mapped) }
                return .success
            }
            commandTargets.append((command, target))
        }
        register(center.togglePlayPauseCommand, as: .togglePlayPause)
        register(center.playCommand, as: .play)
        register(center.pauseCommand, as: .pause)
        register(center.nextTrackCommand, as: .nextTrack)
        register(center.previousTrackCommand, as: .previousTrack)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.claimInfo

        guard mode == .standby else { return }
        coexistToken = AudioSessionCoordinator.shared.beginCoexisting(.mediaTrigger)
        do {
            let silent = try AVAudioPlayer(data: Self.silentWAV())
            silent.volume = 0
            silent.numberOfLoops = -1
            player = silent
            playPending = true
            // Activate off-main first (BJ PR2) so `play()` never implicitly activates the shared
            // session on the main thread, then start the silent loop — unless the claim was
            // released or switched to session control while activation was in flight, in which
            // case a late `play()` would start silence under the conversation that took over.
            Task { @MainActor [weak self] in
                await AudioSessionCoordinator.shared.ensureActiveOffMain()
                guard let self, self.player === silent else { return }
                self.playPending = false
                if !silent.play() {
                    PrivacyLog.device(.nowPlaying, .startFailed, state: PrivacyToken("silentLoop"),
                                      detail: PrivacyToken(self.sessionShape))
                }
            }
        } catch {
            PrivacyLog.device(.nowPlaying, .startFailed, error: SafeErrorSummary(error))
            release()
        }
    }

    func release() {
        player?.stop()
        player = nil
        playPending = false
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets = []
        let infoCenter = MPNowPlayingInfoCenter.default()
        if let info = infoCenter.nowPlayingInfo, Self.isOwnInfo(info) {
            infoCenter.nowPlayingInfo = nil
        }
        if let token = coexistToken {
            AudioSessionCoordinator.shared.endCoexisting(token)
            coexistToken = nil
        }
    }

    /// One second of 16-bit mono silence as a complete WAV file (~16 KB), generated so we ship
    /// no audio asset.
    static func silentWAV(sampleRate: UInt32 = 8000) -> Data {
        let frames = Int(sampleRate)          // 1 second
        let dataSize = UInt32(frames * 2)     // 16-bit mono
        var data = Data(capacity: 44 + frames * 2)
        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append(36 + dataSize); append("WAVE")
        append("fmt "); append(UInt32(16))
        append(UInt16(1))                     // PCM
        append(UInt16(1))                     // mono
        append(sampleRate)
        append(sampleRate * 2)                // byte rate
        append(UInt16(2))                     // block align
        append(UInt16(16))                    // bits per sample
        append("data"); append(dataSize)
        data.append(contentsOf: [UInt8](repeating: 0, count: frames * 2))
        return data
    }
}
