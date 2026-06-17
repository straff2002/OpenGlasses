import Foundation

/// Pure reference-counting state machine for the single shared `DeviceSession` (Additional
/// Capabilities #3). The DAT SDK allows **one session per device**, so the camera and the in-lens
/// display can't each spin up their own without one falling back to the iPhone-camera path. This
/// tracks which capabilities currently want the session and answers the two decisions a coordinator
/// needs — *should I create it now?* (first holder) and *should I tear it down?* (last holder) —
/// with no SDK types, so the logic is fully unit-testable.
struct DeviceSessionOwnership: Equatable {

    /// A consumer that can hold the shared session.
    enum Capability: String, CaseIterable, Hashable {
        case camera
        case display
    }

    private(set) var holders: Set<Capability> = []

    /// Record that `capability` now wants the session. Returns `true` when this is the **first**
    /// holder — i.e. the caller must create the session. Idempotent: re-acquiring an existing holder
    /// never reports "first" again.
    @discardableResult
    mutating func acquire(_ capability: Capability) -> Bool {
        let wasEmpty = holders.isEmpty
        let inserted = holders.insert(capability).inserted
        return wasEmpty && inserted
    }

    /// Release `capability`'s hold. Returns `true` when **no holders remain** — i.e. the caller must
    /// tear the session down. Releasing a capability that isn't holding is a no-op (returns `false`).
    @discardableResult
    mutating func release(_ capability: Capability) -> Bool {
        guard holders.remove(capability) != nil else { return false }
        return holders.isEmpty
    }

    /// Whether any capability currently holds the session.
    var isHeld: Bool { !holders.isEmpty }

    /// Whether more than one capability holds it — i.e. the session is genuinely *shared* (the win:
    /// camera + display live on one session instead of contending).
    var isShared: Bool { holders.count > 1 }

    func holds(_ capability: Capability) -> Bool { holders.contains(capability) }
}
