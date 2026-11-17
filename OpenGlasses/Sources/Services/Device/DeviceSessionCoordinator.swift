import Foundation
#if !AVENKIN_PHONE_ONLY
import MWDATCore
#endif
/// The minimal surface the coordinator needs from a device session, so its lifecycle/ref-counting is
/// testable without the SDK. `MWDATCore.DeviceSession` already has `stop()`, so it conforms with no
/// new code; tests inject a fake.
protocol DeviceSessionHandle: AnyObject {
    func stop()
    /// The session has stopped or is stopping, so it can't be lent again: the next `acquire`
    /// creates a fresh one.
    var hasEnded: Bool { get }
}

#if !AVENKIN_PHONE_ONLY
extension DeviceSession: DeviceSessionHandle {
    var hasEnded: Bool { state == .stopped || state == .stopping }
}
#endif

/// Owns the single shared `DeviceSession` and lends it to the capabilities that want the glasses
/// (Additional Capabilities #3). The first capability to `acquire` triggers creation; the last to
/// `release` tears it down — so the camera and the in-lens display can run on **one** session instead
/// of contending (the SDK allows only one per device). All the *decision* logic lives in the pure,
/// fully-tested `DeviceSessionOwnership`; this is the thin `@MainActor` layer that holds the real
/// session and is itself testable via an injected session factory.
///
/// Both glasses capabilities borrow from here: `MetaCameraBackend` (`acquire(.camera)`, handed back
/// in its session reset) and `MetaDisplayBackend` (`acquire(.display)` through `DATDisplaySession`).
/// Before they did, each created its own session for the same pair, and whichever came second was
/// refused — a Ray-Ban Display report (build 705) shows `sessionAlreadyExists` on the lens for as
/// long as the camera held the glasses. Nothing else may call `Wearables.shared.createSession`
/// (`SharedDeviceSessionTests` reads the sources for it).
@MainActor
final class DeviceSessionCoordinator {

    typealias Capability = DeviceSessionOwnership.Capability

    /// The app-wide coordinator. Its factory creates a real `DeviceSession` lazily on first
    /// `acquire`, so constructing `shared` touches no SDK. Bound to the pair whose link is connected
    /// when that is known (`CameraDeviceBinding`'s reason: with two pairs listed, the first may be
    /// away), else to the SDK's own choice through one long-lived selector.
    static let shared = DeviceSessionCoordinator(makeSession: { deviceId in
        // Configure on demand: `Wearables.shared` traps rather than throws when unconfigured, so
        // without this an acquire on a device where configure() failed would kill the process.
        try WearablesBootstrap.requireConfigured()
        #if !AVENKIN_PHONE_ONLY
        if let deviceId {
            return try Wearables.shared.createSession(deviceSelector: SpecificDeviceSelector(device: deviceId))
        }
        return try Wearables.shared.createSession(deviceSelector: autoSelector)
        #else
        throw WearablesBootstrap.Unavailable(reason: GlassesSupportPolicy.unavailableReason())
        #endif
    })

    #if !AVENKIN_PHONE_ONLY
    /// Created on first use, after configure, and kept: a selector made at the moment of the
    /// session has not yet heard the device list (Meta's guide: `noEligibleDevice`).
    private static let autoSelector = AutoDeviceSelector(wearables: Wearables.shared)
    #endif

    /// The listed pair whose link is connected, from the app's connection owner. Used when a
    /// capability doesn't name a device itself.
    var readConnectedDevice: () -> String? = { nil }

    private let makeSession: (_ deviceId: String?) throws -> DeviceSessionHandle
    private var ownership = DeviceSessionOwnership()
    private var handle: DeviceSessionHandle?

    /// Observability for tests / diagnostics — how many sessions this coordinator has created and
    /// torn down over its lifetime.
    private(set) var createCount = 0
    private(set) var teardownCount = 0

    init(makeSession: @escaping (_ deviceId: String?) throws -> DeviceSessionHandle) {
        self.makeSession = makeSession
    }

    // MARK: - State

    var holders: Set<Capability> { ownership.holders }
    var isShared: Bool { ownership.isShared }
    var isHeld: Bool { ownership.isHeld }
    var currentHandle: DeviceSessionHandle? { handle }

    // MARK: - Lifecycle

    /// Lend the shared session to `capability`, creating it on the first acquire. The caller then
    /// adds its own capability to the returned session (`addCamera` for the camera, `addDisplay` for
    /// the HUD).
    /// `deviceId` names the pair for a session created now; nil uses `readConnectedDevice`. A
    /// session that is already lent is shared whatever pair is named: there is one per pair, and
    /// both capabilities follow the same connected pair.
    @discardableResult
    func acquire(_ capability: Capability, deviceId: String? = nil) throws -> DeviceSessionHandle {
        // A session that stopped under its holders (a link drop, the glasses ending it) is not
        // lent again; the holders are kept and the next one is created for them.
        if let handle, handle.hasEnded { self.handle = nil }
        let session: DeviceSessionHandle
        if let handle {
            session = handle
        } else {
            // Create before recording the holder, so a failed creation leaves state untouched.
            session = try makeSession(deviceId ?? readConnectedDevice())
            handle = session
            createCount += 1
        }
        ownership.acquire(capability)
        return session
    }

    /// Release `capability`'s hold; stops + drops the session once the last holder leaves.
    /// Returns whether it stopped the session (false while another capability still holds it, or
    /// when `capability` held nothing), so a caller waits for the stop only when there is one.
    @discardableResult
    func release(_ capability: Capability) -> Bool {
        guard ownership.release(capability) else { return false }   // others still hold it
        handle?.stop()
        handle = nil
        teardownCount += 1
        return true
    }

    func holds(_ capability: Capability) -> Bool { ownership.holds(capability) }

    /// Forget a session that died underneath us (the SDK reported it `.stopped`) **without** changing
    /// who holds it, so the next `acquire` recreates a fresh one for the existing holders.
    func invalidate() {
        handle = nil
    }
}
