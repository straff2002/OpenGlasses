#if DAT_EXPERIMENTAL
import Foundation

// Plan NB §5. Compiled only in a project generated with AVENKIN_DAT_EXPERIMENTAL=1 (TestFlight
// only, never submitted for review); `DATExperimentalGuardTests` keeps it that way.

/// What a Motion channel hands on. Every handler runs on the main actor.
struct MotionChannelHandlers: Sendable {
    /// A sample from the Neural Band, in the app's own words.
    var onSample: @MainActor @Sendable (WristSample) -> Void
    /// A sample from anywhere else (the glasses, or a source the SDK could not name): only counted.
    var onOtherSample: @MainActor @Sendable (WristSampleOrigin) -> Void
    var onState: @MainActor @Sendable (MotionChannelState) -> Void
    var onFailure: @MainActor @Sendable (MotionChannelFailure) -> Void
    /// The session under the capability stopped.
    var onEnded: @MainActor @Sendable () -> Void
}

/// The band's motion, added on the shared session for one device.
@MainActor
protocol MotionChannel: AnyObject {
    var state: MotionChannelState { get }
    /// Stops the capability, removes it and hands the session back. Idempotent.
    func stop()
}

/// Where the channel comes from: Meta's SDK in the app (`MetaMotionSource`), a fake in the tests,
/// which never touch `Wearables.shared`. Named apart from the SDK's own `MotionSource` (where a
/// sample came from), which the lane's Meta file maps.
@MainActor
protocol WristMotionSource {
    /// Adds Motion at 30 Hz on the shared session for `deviceId` and starts it. Throws a
    /// `MotionChannelFailure`.
    func open(deviceId: String, handlers: MotionChannelHandlers) async throws -> MotionChannel
}
#endif
