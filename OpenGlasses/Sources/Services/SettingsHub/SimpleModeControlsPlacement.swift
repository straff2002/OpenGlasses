import Foundation

/// Where Simple Mode and Lock Settings are drawn.
///
/// They are the owner's hand-off controls, so they stay off the hub for someone who never hands the
/// phone over: while Simple Mode is off, both live on the Advanced & Support page under Handing It
/// Over. Simple Mode hides Advanced, so while it is on the hub carries one Leave Simple Mode row
/// (behind the owner gate) and nothing else of them. That also keeps Lock Settings out of reach of
/// the person the phone was handed to. Under an organisation's edition both are locked with the
/// rest of what the owner configures, and the technician sees neither (Plan HA C4).
enum SimpleModeControlsPlacement: Equatable, Sendable {
    /// Simple Mode and Lock Settings, on the Advanced & Support page.
    case handOverSection
    /// One Leave Simple Mode row on the hub.
    case leaveRowOnHub
    /// Not drawn anywhere.
    case none

    static func place(simpleModeOn: Bool, ownerControlsShown: Bool) -> SimpleModeControlsPlacement {
        guard ownerControlsShown else { return .none }
        return simpleModeOn ? .leaveRowOnHub : .handOverSection
    }
}
