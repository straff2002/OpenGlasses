#if DAT_EXPERIMENTAL
import Foundation

// Plan JV P1. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// One request from the glasses' assistant to open the app, as the service needs it: which glasses
/// it came from, and the one way to answer it.
struct VoiceInvocationRequest: Sendable {
    let deviceId: String
    /// Answers the request: success or failure, with at most one short sentence. Returns whether
    /// the SDK accepted the answer. Called exactly once (`GlassesVoiceInvocationService`).
    let respond: @Sendable (_ success: Bool, _ actionOutput: String?) async -> Bool
}

/// One device's voice-invocation stream.
@MainActor
protocol VoiceInvocationChannel: AnyObject {
    func start() throws
    func stop()
}

/// Where the streams come from: Meta's SDK in the app (`MetaVoiceInvocationSource`), a fake in the
/// tests, which never touch `Wearables.shared`.
@MainActor
protocol VoiceInvocationSource {
    func openChannel(deviceId: String,
                     onRequest: @escaping @MainActor @Sendable (VoiceInvocationRequest) -> Void,
                     onFailure: @escaping @MainActor @Sendable (VoiceInvocationFailure) -> Void) throws
        -> VoiceInvocationChannel
    /// An error `openChannel` or `start()` threw, in the app's own words.
    func failure(for error: Error) -> VoiceInvocationFailure
}
#endif
