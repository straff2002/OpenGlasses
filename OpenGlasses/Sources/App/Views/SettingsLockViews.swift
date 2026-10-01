import SwiftUI

// Plan HA C2 — how a setting the organisation locked looks. Locked is never invisible: the
// control stays on screen, read-only, with the organisation named as the reason.

/// The "Managed by ⟨org⟩" row: the hub's Organisation section and the banner on every locked
/// settings screen are the same row.
struct ManagedByOrganisationRow: View {
    let organization: String
    let subtitle: String

    var body: some View {
        OGRow("Managed by \(organization)", icon: "building.2", subtitle: subtitle,
              showsChevron: false) { EmptyView() }
    }
}

/// The banner above a locked settings screen.
struct ManagedLockBanner: View {
    let organization: String
    /// Some rows on the screen are still open (`CategoryLock.partlyOpen`).
    var partly = false

    var body: some View {
        ManagedByOrganisationRow(
            organization: organization,
            subtitle: partly
                ? "Locked rows are set by \(organization). An administrator can change them."
                : "Read only — \(organization) sets these. An administrator can change them."
        )
        .background(OGTheme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A caption under one locked control, for locks that are not a `SettingKey` ceiling.
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

extension View {
    /// A whole settings screen the organisation locked: every control read-only, the banner on top.
    /// Nil leaves the screen as it is.
    @ViewBuilder
    func managedReadOnly(_ organization: String?) -> some View {
        if let organization {
            self
                .disabled(true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ManagedLockBanner(organization: organization)
                }
        } else {
            self
        }
    }

    /// A screen with some rows locked: the banner on top, each locked row disables itself.
    @ViewBuilder
    func managedPartlyLocked(_ organization: String?) -> some View {
        if let organization {
            self.safeAreaInset(edge: .top, spacing: 0) {
                ManagedLockBanner(organization: organization, partly: true)
            }
        } else {
            self
        }
    }
}

/// The organisation's name as a lock's reason.
enum ManagedLockReason {
    static var organization: String {
        PolicyEnvelope.organizationName ?? OrgProfileManager.shared.profile?.organizationName ?? "your organisation"
    }
}
