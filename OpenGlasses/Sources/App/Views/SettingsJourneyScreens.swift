import SwiftUI

// The category screens the settings journey introduces (Plan DE P2).
//
// None of these invent capability logic. Each one *presents* settings that
// already exist — the same `Config` values, written through the same setters,
// with the same permission prompt — so that a capability the hub now names has
// somewhere to land without a single setting being moved.

// MARK: - Works with your iPhone

/// The Apple-app integrations, as an Everyday surface.
///
/// "Turn off the lights", "what's on my calendar", "remind me to…" are day-one
/// voice-assistant expectations and the Apple set needs no configuration: iOS's
/// own permission prompts are the gate. These are the same switches the full
/// tool list offers, presented in the words a new user would look for rather
/// than by tool id. Third-party and self-hosted integrations stay in their own
/// tiers.
struct AppleIntegrationsSettingsScreen: View {
    /// title, tool id, icon, and what it does in one line.
    private struct Integration: Identifiable {
        let id: String
        let title: String
        let icon: String
        let detail: String
    }

    private static let integrations: [Integration] = [
        Integration(id: "smart_home", title: "Home", icon: "house",
                    detail: "Lights, locks, and scenes through HomeKit."),
        Integration(id: "calendar", title: "Calendar", icon: "calendar",
                    detail: "Check what's on, and add events by voice."),
        Integration(id: "reminder", title: "Reminders", icon: "checklist",
                    detail: "Add to your lists and hear what's due."),
        Integration(id: "lookup_contact", title: "Contacts", icon: "person.crop.circle",
                    detail: "Look someone up to call or message them."),
        Integration(id: "music_control", title: "Music", icon: "music.note",
                    detail: "Play, pause, skip, and ask what's playing."),
        Integration(id: "get_directions", title: "Maps Directions", icon: "map",
                    detail: "Get directions to a place, opened in Maps."),
        Integration(id: "set_alarm", title: "Alarms", icon: "alarm",
                    detail: "Set an alarm for a time you say out loud."),
    ]

    @State private var disabledTools: Set<String> = Config.disabledTools
    @State private var permissionDeniedTool: String?
    @AppStorage("myDayEnabled") private var myDayEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("My Day", isOn: $myDayEnabled)
                    .onChange(of: myDayEnabled) { _, enabled in
                        Config.setMyDayEnabled(enabled)
                    }
            } header: {
                Text("Everyday Briefing")
            } footer: {
                Text("Adds a phone and spoken briefing of what matters next from Calendar, Reminders, and Weather. It does not require a display or save a separate copy of your day.")
            }

            Section {
                ForEach(Self.integrations) { integration in
                    integrationRow(integration)
                }
            } header: {
                Text("Apple Apps")
            } footer: {
                Text("These use the apps already on your iPhone, so there is nothing to sign into. iOS asks for permission the first time you switch one on, and you can change your mind in iOS Settings at any point. Destructive actions still ask before they happen.")
            }
        }
        .navigationTitle("Works with your iPhone")
        .ogFormStyle()
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
            Text("\(permissionDeniedTool ?? "Permission") was denied. You can grant it in Settings.")
        }
    }

    private func integrationRow(_ integration: Integration) -> some View {
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
    }

    /// The same write the full tool list performs, including the permission
    /// request, so the two screens can never disagree about what a switch means.
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

// MARK: - Capture & Streaming

/// The Creator surface: what you record, what you keep, and what you send out
/// live. Every destination here already existed — this is the door that says so.
struct CaptureStreamingSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    RecordingsView(
                        store: appState.recordedSessionStore,
                        controller: appState.sessionRecorder,
                        audioRecorder: appState.audioRecorder
                    )
                } label: {
                    HStack {
                        Label("Recordings", systemImage: "waveform")
                        Spacer()
                        if appState.sessionRecorder.isRecording {
                            OGStatusLabel("Recording", kind: .error, systemImage: "record.circle")
                        }
                    }
                }

                NavigationLink {
                    MeetingRecordsView()
                } label: {
                    Label("Meeting Records", systemImage: "text.book.closed")
                }
            } header: {
                Text("What You Keep")
            } footer: {
                Text("Finished recordings with playback and transcripts, and the summaries the Meeting Summary tool saves.")
            }

            Section {
                NavigationLink {
                    ServicesSettingsView(appState: appState)
                } label: {
                    HStack {
                        Label("Camera, Recording & Streaming", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        if Config.isBroadcastConfigured {
                            OGStatusLabel("Ready", kind: .ok)
                        }
                    }
                }
            } header: {
                Text("Going Live")
            } footer: {
                Text("Capture quality, where recordings are copied, your streaming platform and key, and chat read-aloud — the assistant speaking your live chat into your ear — all live under Services.")
            }
        }
        .navigationTitle("Capture & Streaming")
        .ogFormStyle()
    }
}

// MARK: - Display & HUD

/// The Power surface for glasses with an in-lens display: the display itself,
/// and everything that draws on it.
struct DisplayHUDSettingsScreen: View {
    @ObservedObject var appState: AppState
    @AppStorage("hudMirrorEnabled") private var hudMirrorEnabled = false
    @AppStorage("displayBackend") private var displayBackendRaw = DisplayBackendChoice.metaRayBan.rawValue

    private var displayedDisplayBackendName: String {
        DisplayBackendChoice(rawValue: displayBackendRaw)?.displayName ?? Config.displayBackend.displayName
    }

    var body: some View {
        Form {
            Section {
                InfoToggle(
                    title: "Glasses Display (HUD)",
                    isOn: Binding(
                        get: { Config.glassesDisplayEnabled },
                        set: { newValue in
                            Config.setGlassesDisplayEnabled(newValue)
                            if !newValue {
                                Task { await appState.glassesDisplay.shutdown() }
                            }
                        }
                    ),
                    info: "Shows AI responses, live captions, notifications and turn-by-turn guidance on the in-lens display, and runs interactive task cards you complete hands-free with the Neural Band or voice (\"next\", \"done\", \"skip\", \"back\"). Ray-Ban Display glasses only — no effect on glasses without a built-in display."
                )
                InfoToggle(
                    title: "HUD Choice Buttons",
                    isOn: Binding(
                        get: { Config.hudChoiceButtonsEnabled },
                        set: { Config.setHudChoiceButtonsEnabled($0) }
                    ),
                    info: "When a reply lays out explicit options (\"A) the fast route, B) the scenic route\"), they appear as selectable buttons on the in-lens display — pick one with the Neural Band instead of re-speaking it. Detection is deliberately conservative: plain numbered steps never become buttons."
                )
            } header: {
                Text("In-Lens Display")
            } footer: {
                Text("These are the same switches as under Glasses & Privacy → Hardware & Privacy. Glasses without a display ignore them.")
            }

            Section {
                NavigationLink {
                    HUDMirrorView(router: appState.hudRouter)
                } label: {
                    Label("HUD Mirror (phone preview)", systemImage: "eyeglasses")
                }

                NavigationLink {
                    EvenDisplaySettingsView()
                } label: {
                    HStack {
                        Label("Display Backend", systemImage: "display")
                        Spacer()
                        Text(displayedDisplayBackendName)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    WebHUDMirrorSettingsView()
                } label: {
                    HStack {
                        Label("Web HUD Mirror", systemImage: "globe.desk")
                        Spacer()
                        Text(hudMirrorEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    TeleprompterSettingsView(service: appState.teleprompterService,
                                             store: appState.teleprompterStore)
                } label: {
                    HStack {
                        Label("Teleprompter", systemImage: "text.alignleft")
                        Spacer()
                        if appState.teleprompterService.isActive {
                            OGStatusLabel("Running", kind: .ok)
                        }
                    }
                }
            } header: {
                Text("What Draws On It")
            } footer: {
                Text("Preview the lens on your phone, choose which display hardware to drive, mirror the HUD to a browser, or read a script hands-free.")
            }
        }
        .navigationTitle("Display & HUD")
        .ogFormStyle()
    }
}
