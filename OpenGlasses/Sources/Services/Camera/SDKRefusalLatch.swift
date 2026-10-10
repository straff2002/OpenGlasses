import Foundation

/// Plan HX P1 — the glasses have refused this build of the app, for the rest of the process (pure).
///
/// # The gap this closes
///
/// A pair of glasses that needs an app built against a newer SDK ends every device session with
/// `insufficientSDKVersion`. Nothing on the glasses or in Meta AI changes that; only a newer build
/// does. The camera nonetheless forgot the refusal at the start of every session cycle (the
/// backend clears its compatibility notice there, so that a notice from before a glasses update
/// cannot block attempts that would now succeed), and so every capture and every stream start
/// built a session, waited for the glasses to refuse it again, and failed seconds later.
///
/// # The rule
///
/// Once a session has been refused, the refusal is known until relaunch. There is no way to clear
/// the latch, on purpose: the only thing that changes the answer is a different build, and a
/// different build is a different process. Every later camera start fails at once with the
/// app-update sentence instead of a session attempt, and the backend's per-cycle clear, which
/// goes on clearing every other notice, leaves this one standing.
///
/// # What does not latch
///
/// The glasses' own compatibility reading (`GlassesCompatibility.sdkUpdateRequired`). The SDK
/// describes it as "some features may be unavailable", and it has two different answers for an
/// old build when a session is actually asked for: this terminal one, and a nonblocking warning
/// with which the session carries on (`DATCompatibilityMessage.isAdvisory`). The reading cannot
/// say which of the two the glasses will give, and latching on it could switch off a camera that
/// works. So the reading is announced (`CompatibilityNoticePolicy`) and the first session the
/// glasses refuse is what latches: one attempt per process, not one per start.
struct SDKRefusalLatch: Equatable, Sendable {

    private(set) var isLatched = false

    /// A device session reported `DeviceSessionError.insufficientSDKVersion`
    /// (`DATCompatibilityMessage.isSDKRefusal`). Returns whether this call is the one that
    /// latched; a second report changes nothing.
    @discardableResult
    mutating func latch() -> Bool {
        guard !isLatched else { return false }
        isLatched = true
        return true
    }

    /// What a camera start is refused with, or nil when it may go ahead. The same sentence the
    /// refusal itself is reported with, so the first failure and every later one read alike.
    var startRefusal: String? {
        isLatched ? DATCompatibilityMessage.appUpdateRequired : nil
    }

    /// The compatibility notice that stands after the backend reported `reported`, where nil is
    /// its per-cycle clear. A clear takes away whatever the backend had said and leaves the
    /// refusal; anything the backend says is newer and is shown as said.
    func notice(afterBackendReported reported: String?) -> String? {
        reported ?? startRefusal
    }
}
