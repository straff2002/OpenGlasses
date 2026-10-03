import SwiftUI

// Plan HA C4 — how a setting the organisation locked looks. In the technician's view it is not
// drawn at all (`SettingsVisibilityPolicy`); the hub's Organisation section says so in one line, and
// the organisation's page lists what is hidden. What is still drawn locked — an administrator's
// view of a ceiling, or a protection in `SettingsVisibilityPolicy.alwaysShown` — is read-only with
// the organisation named as the reason.

/// The "Managed by ⟨org⟩" row at the top of the hub's Organisation section.
struct ManagedByOrganisationRow: View {
    let organization: String
    let subtitle: String
    var showsChevron = false

    var body: some View {
        OGRow("Managed by \(organization)", icon: "building.2", subtitle: subtitle,
              showsChevron: showsChevron) { EmptyView() }
    }
}

/// A caption under one locked control that is still drawn.
struct ManagedLockNote: View {
    let organization: String

    var body: some View {
        Label {
            Text("Set by \(organization)")
        } icon: {
            Image(systemName: "lock.fill")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// What a hidden category's screen draws if it is ever reached anyway — an administrator session
/// ending while the screen is open, or a link that outlived its row. None of the screen's own
/// controls are built, so nothing of it reaches the screen or VoiceOver.
struct ManagedHiddenScreen: View {
    let organization: String

    var body: some View {
        OGScrollPage {
            OGNotice(text: "\(organization) sets these settings, so they aren't shown on this phone. Settings › Organisation lists what \(organization) sets.",
                     systemImage: "building.2")
        }
    }
}

/// The organisation's name as a lock's reason.
@MainActor
enum ManagedLockReason {
    static var organization: String {
        PolicyEnvelope.organizationName ?? OrgProfileManager.shared.profile?.organizationName ?? "your organisation"
    }
}
