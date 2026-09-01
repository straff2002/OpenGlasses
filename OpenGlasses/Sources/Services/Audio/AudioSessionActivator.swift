import AVFoundation
import Foundation

/// Activates an `AVAudioSession` with graceful degradation.
///
/// The realtime managers prefer a specific category/mode/options for echo cancellation and
/// routing (`.voiceChat`/`.videoChat`, Bluetooth + speaker). If the OS won't grant that
/// combination on the current route, a bare `try session.setActive(true)` throws and kills the
/// whole session — and the live conversation with it. This activator instead retries once with
/// a conservative `.default` configuration before giving up, and surfaces a typed
/// `AudioSessionError.activationFailed` only if even the fallback fails.
enum AudioSessionActivator {
    /// Configure and activate `session`, falling back to `.default` + `[.defaultToSpeaker]` if
    /// the preferred configuration can't be activated.
    ///
    /// - Parameter configure: run after `setCategory` and before `setActive` on each attempt —
    ///   use it for non-fatal hints like `setPreferredSampleRate` (call them with `try?` inside;
    ///   a rejected hint must not abort activation).
    static func activate(
        _ session: AudioSessionConforming,
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions,
        configure: (AudioSessionConforming) -> Void = { _ in }
    ) throws {
        // Clear any stale active route first so a pending route change doesn't block activation.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)

        do {
            try session.setCategory(category, mode: mode, options: options)
            configure(session)
            try session.setActive(true, options: [])
        } catch {
            PrivacyLog.audio(.session, .sessionConfigureFailed,
                             detail: PrivacyToken(mode.rawValue), error: SafeErrorSummary(error))
            do {
                try session.setCategory(category, mode: .default, options: [.defaultToSpeaker])
                configure(session)
                try session.setActive(true, options: [])
                PrivacyLog.audio(.session, .sessionFallbackActivated)
            } catch {
                throw AudioSessionError.activationFailed(error.localizedDescription)
            }
        }
    }
}
