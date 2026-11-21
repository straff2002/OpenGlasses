#if DAT_EXPERIMENTAL
import Foundation

// Plan JV P2. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// What the probe hears from an open channel. Every handler runs on the main actor.
struct InputsChannelHandlers: Sendable {
    var onInput: @MainActor @Sendable (GlassesInput) -> Void
    var onState: @MainActor @Sendable (InputsProbeState) -> Void
    var onFailure: @MainActor @Sendable (InputsProbeFailure) -> Void
    /// The session under the capability stopped.
    var onEnded: @MainActor @Sendable () -> Void
    /// The capability's event stream finished (taken off, or a terminal error): nothing more will
    /// arrive on it.
    var onInputsEnded: @MainActor @Sendable () -> Void
}

/// The glasses' touch inputs, added on the shared session for one device.
@MainActor
protocol InputsChannel: AnyObject {
    /// The capability's state now. Adding Inputs only begins activation, and the state publisher
    /// does not replay, so the probe reads this once the channel is open in case `.active` came
    /// before its listener.
    var state: InputsProbeState { get }
    /// Cancels the event task, removes the capability and hands the session back. Idempotent.
    func stop()
}

/// Where the channel comes from: Meta's SDK in the app (`MetaInputsSource`), a fake in the tests,
/// which never touch `Wearables.shared`.
@MainActor
protocol InputsSource {
    /// Adds the capability with the probe's configuration (`InputsProbeConfiguration`), on the
    /// shared session for `deviceId`. Throws an `InputsProbeFailure`.
    func open(deviceId: String, handlers: InputsChannelHandlers) async throws -> InputsChannel
}
#endif
