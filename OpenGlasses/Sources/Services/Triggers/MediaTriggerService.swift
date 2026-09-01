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
    /// Begin holding Now Playing: start silent playback and register remote-command handlers.
    /// Temple-gesture commands are delivered to `onCommand` until `release()`.
    func claim(onCommand: @escaping (MediaRemoteCommand) -> Void)
    /// Drop the claim: stop playback, unregister handlers, clear our Now Playing info.
    func release()
}

/// Temple-tap hands-free trigger (Plan CH): claims Now Playing so the glasses' temple gestures
/// (standard AVRCP media commands) reach us, and a double-tap (next-track) starts listening —
/// no wake word, no phone touch.
///
/// The claim is governed entirely by the pure `MediaTriggerPolicy`: claim only when the user
/// isn't playing anything and no realtime session holds the audio lease; release the moment
/// external audio starts. Fired triggers route through a `TriggerGate` (debounce + suppression,
/// same as the alternative triggers) to `onTrigger`, which `AppState` wires to the same entry
/// point as the wake word.
///
/// All inputs are injected closures and the claimer is a protocol, so every state transition is
/// drivable headlessly; only `SilentNowPlayingClaimer` needs a device (P3).
@MainActor
final class MediaTriggerService {

    /// Fired when a gated temple-tap trigger passes. `AppState` routes this to the wake path.
    var onTrigger: (() -> Void)?

    /// Whether triggers are currently suppressed (conversation in progress etc.). Mirrors the
    /// wake-word guard; `AppState` supplies it.
    var isSuppressed: () -> Bool = { false }

    /// Whether a realtime voice session (Gemini Live / OpenAI Realtime) is running.
    var realtimeSessionActive: () -> Bool = { false }

    /// Posted (by `MusicControlTool`) just before a command is issued to the *user's* player,
    /// so we stand down pre-emptively instead of racing their playback for Now Playing.
    static let userPlaybackRequested = Notification.Name("MediaTriggerUserPlaybackRequested")

    private let isEnabled: () -> Bool
    private let isOtherAudioPlaying: () -> Bool
    private let leaseOwner: () -> AudioSessionOwner?
    private let claimer: NowPlayingClaiming
    private let clock: () -> TimeInterval
    private var gate: TriggerGate

    private(set) var isClaimed = false
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []
    private var standDownReevaluation: Task<Void, Never>?

    init(claimer: NowPlayingClaiming? = nil,
         isEnabled: @escaping () -> Bool = { Config.mediaTriggerEnabled },
         isOtherAudioPlaying: @escaping () -> Bool = { AVAudioSession.sharedInstance().isOtherAudioPlaying },
         leaseOwner: @escaping () -> AudioSessionOwner? = { AudioSessionCoordinator.shared.currentOwner },
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         debounceInterval: TimeInterval = 2.0) {
        self.claimer = claimer ?? SilentNowPlayingClaimer()
        self.isEnabled = isEnabled
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.leaseOwner = leaseOwner
        self.clock = clock
        self.gate = TriggerGate(debounceInterval: debounceInterval, minimumConfidence: 1.0)
    }

    // MARK: - Policy application (tested)

    /// Re-run the claim/release policy against the live inputs and apply the decision.
    func evaluate() {
        let conditions = MediaTriggerConditions(
            triggerEnabled: isRunning && isEnabled(),
            userAudioPlaying: isOtherAudioPlaying(),
            realtimeSessionActive: realtimeSessionActive(),
            leaseOwner: leaseOwner(),
            isClaimed: isClaimed)
        switch MediaTriggerPolicy.decide(conditions) {
        case .claim:
            isClaimed = true
            claimer.claim { [weak self] command in
                self?.handleRemoteCommand(command)
            }
            PrivacyLog.device(.nowPlaying, .claimed)
        case .release:
            releaseClaim()
        case .defer:
            break
        }
    }

    /// Feed a temple-gesture command. Fires `onTrigger` iff the claim is live, the gesture is in
    /// the v1 grammar (next-track only), and the gate passes (debounce, not suppressed). Returns
    /// whether it fired.
    @discardableResult
    func handleRemoteCommand(_ command: MediaRemoteCommand) -> Bool {
        guard isClaimed, isEnabled() else { return false }
        guard MediaTriggerPolicy.firesTrigger(command) else { return false }
        guard gate.shouldFire(at: clock(), confidence: 1.0, suppressed: isSuppressed()) else {
            return false
        }
        onTrigger?()
        return true
    }

    /// Stand down *before* the user's playback starts (a `MusicControlTool` command is on its
    /// way to their player): release now so we never race them for Now Playing, then re-evaluate
    /// shortly after — if their playback didn't materialise, the trigger resumes.
    func standDownForUserPlayback() {
        releaseClaim()
        standDownReevaluation?.cancel()
        standDownReevaluation = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
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
        evaluate()
    }

    /// Stop observing and drop any claim.
    func stop() {
        isRunning = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        standDownReevaluation?.cancel()
        releaseClaim()
    }

    /// Re-apply the setting (call when the user toggles it in Settings).
    func refresh() {
        stop()
        gate.reset()
        start()
    }

    // MARK: - Private

    private func releaseClaim() {
        guard isClaimed else { return }
        isClaimed = false
        claimer.release()
        PrivacyLog.device(.nowPlaying, .released)
    }
}

// MARK: - Production claimer (device runtime)

/// Holds Now Playing the standard way: a silent looping zero-volume `AVAudioPlayer` on the
/// shared audio session plus `MPRemoteCommandCenter` handlers. Registered with the Plan AS
/// coordinator as a *coexisting* rider — it lives under the wake-word listener's session and
/// must never preempt or deactivate it.
///
/// Device-pending (Plan CH P3): whether iOS grants Now Playing to a `mixWithOthers` session,
/// and which temple gestures arrive as which AVRCP commands on the glasses firmware, can only
/// be confirmed on hardware.
@MainActor
final class SilentNowPlayingClaimer: NowPlayingClaiming {

    /// Title we publish while holding the claim — recognisable so `NowPlayingSnapshot` (the
    /// "what's playing?" reader) can filter *us* out instead of reporting our own silence.
    nonisolated static let sentinelTitle = "OpenGlasses Temple Trigger"

    /// Whether a Now Playing info dictionary is our own claim rather than real user media.
    nonisolated static func isOwnInfo(_ info: [String: Any]) -> Bool {
        info[MPMediaItemPropertyTitle] as? String == sentinelTitle
    }

    private var player: AVAudioPlayer?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var coexistToken: UUID?

    func claim(onCommand: @escaping (MediaRemoteCommand) -> Void) {
        guard player == nil else { return }
        coexistToken = AudioSessionCoordinator.shared.beginCoexisting(.mediaTrigger)

        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, as mapped: MediaRemoteCommand) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                Task { @MainActor in onCommand(mapped) }
                return .success
            }
            commandTargets.append((command, target))
        }
        register(center.nextTrackCommand, as: .nextTrack)
        register(center.togglePlayPauseCommand, as: .togglePlayPause)
        register(center.previousTrackCommand, as: .previousTrack)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: Self.sentinelTitle,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]

        do {
            let silent = try AVAudioPlayer(data: Self.silentWAV())
            silent.volume = 0
            silent.numberOfLoops = -1
            player = silent
            // Activate off-main first (BJ PR2) so `play()` never implicitly activates the shared
            // session on the main thread, then start the silent loop.
            Task { @MainActor in
                await AudioSessionCoordinator.shared.ensureActiveOffMain()
                silent.play()
            }
        } catch {
            PrivacyLog.device(.nowPlaying, .startFailed, error: SafeErrorSummary(error))
            release()
        }
    }

    func release() {
        player?.stop()
        player = nil
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
