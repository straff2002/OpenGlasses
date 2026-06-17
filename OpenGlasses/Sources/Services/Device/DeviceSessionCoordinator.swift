import Foundation
import MWDATCore

/// The minimal surface the coordinator needs from a device session, so its lifecycle/ref-counting is
/// testable without the SDK. `MWDATCore.DeviceSession` already has `stop()`, so it conforms with no
/// new code; tests inject a fake.
protocol DeviceSessionHandle: AnyObject {
    func stop()
}

extension DeviceSession: DeviceSessionHandle {}

/// Owns the single shared `DeviceSession` and lends it to the capabilities that want the glasses
/// (Additional Capabilities #3). The first capability to `acquire` triggers creation; the last to
/// `release` tears it down — so the camera and the in-lens display can run on **one** session instead
/// of contending (the SDK allows only one per device). All the *decision* logic lives in the pure,
/// fully-tested `DeviceSessionOwnership`; this is the thin `@MainActor` layer that holds the real
/// session and is itself testable via an injected session factory.
///
/// Adoption is staged: this is the tested coordinator. Wiring `CameraService` and
/// `GlassesDisplayService` to source their session here (and the on-glasses "camera + HUD at once"
/// check) is the device-only follow-up — it can't be validated without Display hardware.
@MainActor
final class DeviceSessionCoordinator {

    typealias Capability = DeviceSessionOwnership.Capability

    /// The app-wide coordinator. Its factory creates a real auto-selected `DeviceSession` lazily on
    /// first `acquire`, so constructing `shared` touches no SDK.
    static let shared = DeviceSessionCoordinator(makeSession: {
        try Wearables.shared.createSession(deviceSelector: AutoDeviceSelector(wearables: Wearables.shared))
    })

    private let makeSession: () throws -> DeviceSessionHandle
    private var ownership = DeviceSessionOwnership()
    private var handle: DeviceSessionHandle?

    /// Observability for tests / diagnostics — how many sessions this coordinator has created and
    /// torn down over its lifetime.
    private(set) var createCount = 0
    private(set) var teardownCount = 0

    init(makeSession: @escaping () throws -> DeviceSessionHandle) {
        self.makeSession = makeSession
    }

    // MARK: - State

    var holders: Set<Capability> { ownership.holders }
    var isShared: Bool { ownership.isShared }
    var isHeld: Bool { ownership.isHeld }
    var currentHandle: DeviceSessionHandle? { handle }

    // MARK: - Lifecycle

    /// Lend the shared session to `capability`, creating it on the first acquire. The caller then
    /// adds its own capability to the returned session (`addStream` for the camera, `addDisplay` for
    /// the HUD).
    @discardableResult
    func acquire(_ capability: Capability) throws -> DeviceSessionHandle {
        let session: DeviceSessionHandle
        if let handle {
            session = handle
        } else {
            // Create before recording the holder, so a failed creation leaves state untouched.
            session = try makeSession()
            handle = session
            createCount += 1
        }
        ownership.acquire(capability)
        return session
    }

    /// Release `capability`'s hold; stops + drops the session once the last holder leaves.
    func release(_ capability: Capability) {
        guard ownership.release(capability) else { return }   // others still hold it
        handle?.stop()
        handle = nil
        teardownCount += 1
    }

    /// Forget a session that died underneath us (the SDK reported it `.stopped`) **without** changing
    /// who holds it, so the next `acquire` recreates a fresh one for the existing holders.
    func invalidate() {
        handle = nil
    }
}
