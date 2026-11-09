import SwiftUI

// Simple Mode and Lock Settings, where `SimpleModeControlsPlacement` puts them: a Handing It Over
// section on the Advanced & Support page while Simple Mode is off, and one Leave Simple Mode row on
// the hub while it is on. Both read and write the same keys as `Config`, so the hub redraws when
// either changes.

/// Advanced & Support › Handing It Over. Drawn only while Simple Mode is off.
struct HandOverSection: View {
    @AppStorage("simpleModeEnabled") private var simpleModeEnabled = false
    @AppStorage("settingsOwnerGateEnabled") private var settingsOwnerGateEnabled = false
    @ObservedObject private var adminGate = AdminGate.shared
    @Environment(\.dismiss) private var dismiss

    private var ownerControls: SettingPresentation { adminGate.presentation(.area(.ownerControls)) }

    var body: some View {
        if SimpleModeControlsPlacement.place(simpleModeOn: simpleModeEnabled,
                                             ownerControlsShown: ownerControls.isShown) == .handOverSection {
            OGSection(
                header: "Handing It Over",
                footer: "Simple Mode hides model, persona, behavior, tool, integration, Field Assist and advanced settings — for handing the device to someone who just needs it to work. While it's on, Settings shows Leave Simple Mode, which asks for Face ID or your passcode. Lock Settings asks every time Settings opens."
            ) {
                OGRow(
                    "Simple Mode",
                    isOn: Binding(
                        get: { simpleModeEnabled },
                        set: { turnOn($0) }
                    ),
                    icon: "dial.low"
                )
                .disabled(!ownerControls.isEditable)
                OGDivider()
                OGRow("Lock Settings", isOn: $settingsOwnerGateEnabled, icon: "faceid")
                    .disabled(!ownerControls.isEditable)
                if !ownerControls.isEditable {
                    OGDivider()
                    ManagedLockNote(organization: ManagedLockReason.organization)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    /// Turning it on needs no gate (`OwnerGatePolicy`), and this page is one Simple Mode hides, so
    /// it goes back to the hub, where Leave Simple Mode now is. Leaving is never done from here.
    private func turnOn(_ on: Bool) {
        guard on, !OwnerGatePolicy.requiresGate(togglingSimpleModeTo: true, currentlyEnabled: simpleModeEnabled)
        else { return }
        simpleModeEnabled = true
        dismiss()
    }
}

/// The hub's way out of Simple Mode. Leaving re-exposes the owner's settings, decrypted key fields
/// included, so it needs a fresh device-owner grant every time.
struct LeaveSimpleModeSection: View {
    /// False where the organisation locked the owner controls but an administrator can see them.
    let isEditable: Bool
    @AppStorage("simpleModeEnabled") private var simpleModeEnabled = false
    @State private var exitGate = OwnerGateMachine()

    var body: some View {
        OGSection(footer: "Model, tool, connection, Field Assist and advanced settings are hidden. Leaving asks for Face ID or your passcode.") {
            Button {
                leave()
            } label: {
                OGRow("Leave Simple Mode", icon: "dial.low", showsChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            if !isEditable {
                OGDivider()
                ManagedLockNote(organization: ManagedLockReason.organization)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            if exitGate.lastFailed {
                OGDivider()
                OGStatusLabel("Couldn't verify it's you — Simple Mode stays on.", kind: .error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
    }

    private func leave() {
        guard exitGate.begin() else { return }
        OwnerGateAuth.authenticate(reason: String(localized: "Verify it's you to leave Simple Mode")) { granted in
            exitGate.finish(success: granted)
            if exitGate.consume() {
                simpleModeEnabled = false
            }
        }
    }
}
