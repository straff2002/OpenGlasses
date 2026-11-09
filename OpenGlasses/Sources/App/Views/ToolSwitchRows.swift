import SwiftUI

/// One of the Apple-app tool switches, in the words a person looks for (Plan HA, lifted for Plan
/// KW §1 so the Music screen can show Music and Podcasts too).
struct AppleIntegration: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let detail: String

    static let all: [AppleIntegration] = [
        AppleIntegration(id: "smart_home", title: String(localized: "Home"), icon: "house",
                         detail: String(localized: "Lights, locks, and scenes through HomeKit.")),
        AppleIntegration(id: "calendar", title: String(localized: "Calendar"), icon: "calendar",
                         detail: String(localized: "Check what's on, and add events by voice.")),
        AppleIntegration(id: "reminder", title: String(localized: "Reminders"), icon: "checklist",
                         detail: String(localized: "Add to your lists and hear what's due.")),
        AppleIntegration(id: "lookup_contact", title: String(localized: "Contacts"), icon: "person.crop.circle",
                         detail: String(localized: "Look someone up to call or message them.")),
        AppleIntegration(id: "music_control", title: String(localized: "Music"), icon: "music.note",
                         detail: String(localized: "Play, pause, skip, and ask what's playing.")),
        AppleIntegration(id: "play_podcast", title: String(localized: "Podcasts"), icon: "antenna.radiowaves.left.and.right",
                         detail: String(localized: "Open a show or its latest episode in Apple Podcasts.")),
        AppleIntegration(id: "get_directions", title: String(localized: "Maps Directions"), icon: "map",
                         detail: String(localized: "Get directions to a place, opened in Maps.")),
        AppleIntegration(id: "set_alarm", title: String(localized: "Alarms"), icon: "alarm",
                         detail: String(localized: "Set an alarm for a time you say out loud.")),
    ]

    /// The switches the Music & Podcasts screen shows.
    static let voicePlayback: [AppleIntegration] = all.filter { ["music_control", "play_podcast"].contains($0.id) }
}

/// The switches themselves, drawn the same wherever they appear: the same `Config.disabledTools`
/// write, the same permission request through `ToolPermissionGate` (two screens offering one switch
/// must not differ in whether iOS gets asked), and an organisation's closed tool left out for the
/// technician and read-only for an administrator.
struct ToolSwitchRows: View {
    let integrations: [AppleIntegration]

    @State private var disabledTools: Set<String> = Config.disabledTools
    @State private var permissionDeniedTool: String?
    @ObservedObject private var adminGate = AdminGate.shared

    /// The ones an organisation hasn't closed for this viewer.
    static func shown(_ integrations: [AppleIntegration], adminGate: AdminGate) -> [AppleIntegration] {
        integrations.filter { adminGate.presentation(.tool($0.id)).isShown }
    }

    var body: some View {
        ForEach(Self.shown(integrations, adminGate: adminGate)) { integration in
            row(integration)
        }
        .onAppear { disabledTools = Config.disabledTools }
        .alert("Permission Denied", isPresented: Binding(
            get: { permissionDeniedTool != nil },
            set: { if !$0 { permissionDeniedTool = nil } }
        )) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                permissionDeniedTool = nil
            }
            Button("Cancel", role: .cancel) { permissionDeniedTool = nil }
        } message: {
            Text("\(permissionDeniedTool ?? "Permission") was denied. You can grant it in iPhone Settings → Apps → Avenkin.")
        }
    }

    private func row(_ integration: AppleIntegration) -> some View {
        Toggle(isOn: Binding(
            get: { !disabledTools.contains(integration.id) },
            set: { setEnabled($0, for: integration.id) }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(integration.title)
                        .font(.body)
                    Text(integration.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: integration.icon)
                    .accessibilityHidden(true)
            }
        }
        // Plan HA C4: only an administrator still sees a closed tool here — off and read-only.
        .disabled(!adminGate.presentation(.tool(integration.id)).isEditable)
    }

    /// The same write the full tool list performs, including the permission
    /// request, so the screens can never disagree about what a switch means.
    private func setEnabled(_ enabled: Bool, for toolName: String) {
        guard enabled else {
            disabledTools.insert(toolName)
            Config.setDisabledTools(disabledTools)
            return
        }
        guard let permission = ToolPermissionGate.permissionName(for: toolName) else {
            disabledTools.remove(toolName)
            Config.setDisabledTools(disabledTools)
            return
        }
        Task {
            if await ToolPermissionGate.requestPermission(for: toolName) {
                disabledTools.remove(toolName)
                Config.setDisabledTools(disabledTools)
            } else {
                permissionDeniedTool = permission
            }
        }
    }
}
