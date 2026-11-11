import SwiftUI

// Category screens the settings hub links to (first written for Plan DE P2; the hub itself is
// Plan HA's fixed list).
//
// None of these invent capability logic. Each one *presents* settings that already exist — the
// same `Config` values, written through the same setters, with the same permission prompt.

// MARK: - Works with your iPhone

/// The Apple-app integrations — Connections › Works with your iPhone (Plan HA). My Day and the AI
/// access switches moved to Everyday (Plan KH P2).
///
/// "Turn off the lights", "what's on my calendar", "remind me to…" are day-one
/// voice-assistant expectations and the Apple set needs no configuration: iOS's
/// own permission prompts are the gate. These are the same switches the full
/// tool list offers, presented in the words a new user would look for rather
/// than by tool id. Third-party and self-hosted integrations stay in their own
/// tiers.
struct AppleIntegrationsSettingsScreen: View {
    /// Plan HA C4: an app switch the organisation closed is not shown to the technician.
    @ObservedObject private var adminGate = AdminGate.shared

    var body: some View {
        Form {
            // The rows, their permission requests and the closed-tool rule are `ToolSwitchRows`,
            // shared with the Music & Podcasts screen (Plan KW §1).
            if !ToolSwitchRows.shown(AppleIntegration.all, adminGate: adminGate).isEmpty {
                Section {
                    ToolSwitchRows(integrations: AppleIntegration.all)
                } header: {
                    Text("Apple Apps")
                } footer: {
                    Text("These use the apps already on your iPhone, so there is nothing to sign into. iOS asks for permission the first time you switch one on, and you can change your mind in iOS Settings at any point. Destructive actions still ask before they happen.")
                }
            }

            Section {
                NavigationLink {
                    WeatherDataAboutView()
                } label: {
                    Label("About Weather Data", systemImage: "cloud.sun")
                }
            } header: {
                Text("Weather")
            } footer: {
                Text("Weather answers and the weather in My Day come from Apple Weather.")
            }
        }
        .navigationTitle("Works with your iPhone")
        .ogFormStyle()
    }
}

// MARK: - Capture & Streaming

/// The Creator surface: what you record, what you keep, and what you send out
/// live. Every destination here already existed — this is the door that says so.
struct CaptureStreamingSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            CaptureStreamingSections(appState: appState)
        }
        .navigationTitle("Capture & Streaming")
        .ogFormStyle()
    }
}

/// The sections themselves, which Devices & Privacy draws on its own page (Plan KH P2).
struct CaptureStreamingSections: View {
    @ObservedObject var appState: AppState
    @AppStorage("hipaaMode") private var hipaaMode = false
    @AppStorage(Config.keepCaptionSessionsKey) private var keepCaptionSessions = false

    var body: some View {
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

            // Plan KP P5: captions run on the phone with or without glasses, so this is here and
            // not under the glasses.
            NavigationLink {
                CaptionSessionsView()
            } label: {
                HStack {
                    Label(String(localized: "Caption Sessions"), systemImage: "captions.bubble")
                    Spacer()
                    Text(keepCaptionSessions && !hipaaMode ? String(localized: "On") : String(localized: "Off"))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("What You Keep")
        } footer: {
            Text("Finished recordings with playback and transcripts, the summaries the Meeting Summary tool saves, and caption sessions if you choose to keep them, for seven days.")
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
}

// MARK: - Display & HUD

/// The Power surface for glasses with an in-lens display: the display itself,
/// and everything that draws on it.
struct DisplayHUDSettingsScreen: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            DisplayHUDSections(appState: appState)
        }
        #if AVENKIN_PHONE_ONLY
        .navigationTitle("Teleprompter")
        #else
        .navigationTitle("Display & HUD")
        #endif
        .ogFormStyle()
    }
}

/// The sections themselves, which Devices & Privacy draws on its own page (Plan KH P2).
struct DisplayHUDSections: View {
    @ObservedObject var appState: AppState
    @AppStorage("hudMirrorEnabled") private var hudMirrorEnabled = false
    #if !AVENKIN_PHONE_ONLY
    @AppStorage("displayBackend") private var displayBackendRaw = DisplayBackendChoice.metaRayBan.rawValue

    private var displayedDisplayBackendName: String {
        DisplayBackendChoice(rawValue: displayBackendRaw)?.displayName ?? Config.displayBackend.displayName
    }
    #endif

    var body: some View {
        #if !AVENKIN_PHONE_ONLY
        Section {
            InfoToggle(
                title: "Glasses Display (HUD)",
                isOn: Binding(
                    get: { Config.glassesDisplayEnabled },
                    set: { newValue in
                        Config.setGlassesDisplayEnabled(newValue)
                        if !newValue {
                            Task { await appState.glassesDisplay.shutdown() }
                        } else {
                            appState.glassesDisplay.wearerTurnedLensOn()
                        }
                    }
                ),
                info: "Shows AI responses, live captions, notifications and turn-by-turn guidance on the in-lens display, and runs interactive task cards you complete hands-free with the Neural Band or voice (\"next\", \"done\", \"skip\", \"back\"). A manual page you ask to see can open on the lens too, where you can zoom in and move around it. Ray-Ban Display glasses only — no effect on glasses without a built-in display."
            )
            InfoToggle(
                title: "HUD Choice Buttons",
                isOn: Binding(
                    get: { Config.hudChoiceButtonsEnabled },
                    set: { Config.setHudChoiceButtonsEnabled($0) }
                ),
                info: "When a reply lays out explicit options (\"A) the fast route, B) the scenic route\"), they appear as selectable buttons on the in-lens display — pick one with the Neural Band instead of re-speaking it. Detection is deliberately conservative: plain numbered steps never become buttons."
            )
            InfoToggle(
                title: "Keep the mic on the iPhone while the display is on",
                isOn: Binding(
                    get: { Config.lensKeepsPhoneMic },
                    set: { Config.lensKeepsPhoneMic = $0 }
                ),
                info: "On Ray-Ban Display, using the glasses' own microphone turns the in-lens display off and shows a call screen over it. With this on, conversations use the iPhone mic while the display is on, even when Microphone is set to Glasses Mic. A headset mic is not affected."
            )
            InfoToggle(
                title: "Say when the display is busy",
                isOn: Binding(
                    get: { Config.displayBusyHintEnabled },
                    set: { Config.setDisplayBusyHintEnabled($0) }
                ),
                info: "While another app is using the in-lens display, answers can't be shown on it. The first answer you hear then is followed once by a short reminder that you can say \"repeat\", \"save that\" or \"tell me more\" instead. The app never takes the display back from the other app."
            )
            InfoToggle(
                title: "Suggested follow-ups on the display",
                isOn: Binding(
                    get: { Config.followUpsOnDisplayEnabled },
                    set: { Config.setFollowUpsOnDisplayEnabled($0) }
                ),
                info: "Up to three short next questions appear as buttons under an answer on the in-lens display. Press one to ask it. The assistant writes them with the answer, so they cost no extra request; they are never spoken and never saved in the conversation."
            )
            // Plan KP §5: the band check, also on the lens launcher.
            NavigationLink {
                BandPracticeView(session: appState.bandPractice)
            } label: {
                Label("Practise the band", systemImage: "hand.tap")
            }
        } header: {
            Text("In-Lens Display")
        } footer: {
            Text("These are the same switches as under Devices & Privacy → Hardware & Privacy. Glasses without a display ignore them.")
        }
        #endif

        Section {
            #if !AVENKIN_PHONE_ONLY
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
                    Text(LocalServiceExposurePolicy.current.permitsListener(for: .webHUDMirror)
                         ? (hudMirrorEnabled ? "On" : "Off") : "Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            #endif

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
            #if !AVENKIN_PHONE_ONLY
            Text("What Draws On It")
            #endif
        } footer: {
            #if AVENKIN_PHONE_ONLY
            Text("Read a script hands-free.")
            #else
            Text("Preview the lens on your phone, choose which display hardware to drive, mirror the HUD to a browser, or read a script hands-free.")
            #endif
        }
    }
}
