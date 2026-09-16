import SwiftUI

/// Settings UI for the Accessibility Tier: master toggle, default reading level, and
/// preferred translation language for A1 Reading Accessibility (these defaults feed the
/// `reading_assist` tool when the user doesn't specify them per request), plus the
/// independent fingerspelling recognition feature (Plan CK) and continuous scene narration
/// (Plan CV), both of which stand on their own rather than under the reading toggle.
@MainActor
struct AccessibilitySettingsView: View {
    @AppStorage("accessibilityModeEnabled") private var enabled: Bool = false
    @AppStorage("fingerspellingEnabled") private var fingerspellingEnabled: Bool = false
    @AppStorage("sceneNarrationEnabled") private var sceneNarrationEnabled: Bool = false
    // Literal rather than `ScanAssistSettingsStore.Key.enabled`: a property initializer can't
    // reach a main-actor-isolated static. `ScanAssistSettingsStoreTests` pins the two together.
    @AppStorage("scanAssistEnabled") private var scanAssistEnabled: Bool = false
    @AppStorage("accessibilityReadingLevel") private var readingLevel: Int = ReadingProfile.Level.adult.rawValue
    @AppStorage("accessibilityReadingLanguage") private var language: String = ReadingProfile.preferredLanguage
    /// Plan FF P0/PR2 — words alongside the lifecycle earcons. The tones play either way.
    @AppStorage("blindAssistantSpokenCues") private var spokenCues: Bool = true
    /// Plan FF P1/PR3 — start the assistant on opening the app.
    @AppStorage("startBlindAssistantOnLaunch") private var startOnLaunch: Bool = false
    /// The same launch decision the app makes, shown as a sentence, so the wearer can find out
    /// what will happen *before* the launch that does or does not happen.
    @State private var launchStatus: String = ""
    @State private var launchBlockedByPreset = false
    /// Disables the tour button for its duration, so a second tap cannot start a second tour
    /// over the first — which, for a control whose whole purpose is teaching sounds apart, would
    /// teach the wrong thing.
    @State private var tourRunning = false

    /// Re-read the launch decision. Cheap — no registration wait — and re-run on appear and on
    /// every change, because the answer depends on settings and permissions this screen does not
    /// own and cannot observe.
    private func refreshLaunchStatus() {
        Task { @MainActor in
            guard let appState = AppStateProvider.shared else {
                launchStatus = "Open the app to see what will happen."
                launchBlockedByPreset = false
                return
            }
            let decision = await appState.blindAssistantLaunchPreview()
            launchStatus = decision.summary
            launchBlockedByPreset = (decision == .skip(.differentAssistantSelected))
        }
    }

    /// Common translation targets offered in the picker. "Device default" clears the override.
    private let languageOptions: [(code: String, label: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("ar", "Arabic"), ("hi", "Hindi")
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable Reading Accessibility", isOn: $enabled)
                    .tint(AppAccent.color)
                    // This switch reveals three whole sections below it. Nothing about flipping a
                    // switch says "and now there is more page" — a sighted user watches the list
                    // grow under their thumb, and on the app's own accessibility screen of all
                    // places, that must not be the sighted-only affordance.
                    .onChange(of: enabled) { _, on in
                        SessionAnnouncer.say(on ? "Reading accessibility on. More settings added below."
                                                : "Reading accessibility off. Its settings are hidden.")
                    }
            } footer: {
                Text("Reads text through the glasses camera using on-device OCR. When enabled, the `reading_assist` tool can read aloud, simplify, translate, or define text you're looking at. Images never leave your device.")
            }

            if enabled {
                Section {
                    Picker("Reading Level", selection: $readingLevel) {
                        ForEach(ReadingProfile.Level.allCases, id: \.rawValue) { level in
                            Text("\(level.rawValue) — \(level.audienceDescription.capitalizedFirst)")
                                .tag(level.rawValue)
                                // The dash is a visual separator; spoken, it is "em dash".
                                .accessibilityLabel("Level \(level.rawValue), \(level.audienceDescription)")
                        }
                    }
                } header: {
                    Text("Simplify Default")
                } footer: {
                    Text("The reading level used when you ask to simplify text without specifying one.")
                }

                Section {
                    Picker("Translate To", selection: $language) {
                        ForEach(languageOptions, id: \.code) { option in
                            Text(option.label).tag(option.code)
                        }
                    }
                } header: {
                    Text("Translation Default")
                } footer: {
                    Text("The target language used when you ask to translate text without specifying one.")
                }

                Section {
                    AssistiveModeToggleView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Assistive Mode")
                } footer: {
                    Text("Real-time scene and social support: periodically reads the camera and speaks calm, concise guidance. Higher urgency (e.g. someone in distress) speaks faster. Pauses the normal wake-word assistant while active.")
                }
            }

            Section {
                Toggle("Enable Scene Narration", isOn: $sceneNarrationEnabled)
                    .tint(AppAccent.color)
                if sceneNarrationEnabled {
                    SceneNarrationToggleView()
                }
            } header: {
                Text("Scene Narration")
            } footer: {
                Text("Describes the space around you as it changes, for moving through somewhere unfamiliar. Watching is silent — descriptions build up so questions about what you're looking at are answered instantly. Speaking them aloud is a separate switch.\n\nTurning watching on starts the glasses camera, and turning it off stops it again unless something else is using it. The camera takes a few seconds to come up, and it's the biggest drain on the glasses battery — so narration says when it's starting, and won't start it at all when the glasses are nearly flat or too warm.\n\nNot continuous coverage: descriptions are generated on this device, which can't run while the app is in the background or the phone is locked. Narration stops there and says so out loud. It also needs glasses that stream live video — on glasses that only take photos it can't run at all.\n\nLive captions take priority: while captions are running, narration keeps watching but stops speaking, so it doesn't talk over what people are saying or end up transcribed as if it were one of them.")
            }

            Section {
                Toggle("Start Blind Assistant When I Open the App", isOn: $startOnLaunch)
                    .tint(AppAccent.color)
                    .onChange(of: startOnLaunch) { _, _ in refreshLaunchStatus() }
                if startOnLaunch {
                    Text(launchStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        // One sentence, not a label and a value: it is a status, and splitting it
                        // makes VoiceOver stop twice on half a thought.
                        .accessibilityElement(children: .combine)
                    if launchBlockedByPreset {
                        Button("Use Blind Assistant as the Live Mode") {
                            Config.setActiveLiveAIModeId(BlindAssistanceContract.presetID)
                            refreshLaunchStatus()
                            SessionAnnouncer.say("Blind Assistant is now the selected live mode.")
                        }
                    }
                    Button("Open iOS Settings for OpenGlasses") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .accessibilityHint("Opens the iOS Settings page where microphone, speech recognition and camera access are granted.")
                }
            } header: {
                Text("Opening the App")
            } footer: {
                Text("Starts a Blind Assistant session as soon as you open OpenGlasses, so the first thing you hear is the assistant becoming ready rather than a screen you have to find. It only starts when Blind Assistant is the selected live mode — turning this on never changes that choice for you.\n\nIf something is missing, it says so out loud instead of starting quietly: which permission is off, or that there is no API key yet. Without the camera it still starts, and says it can hear but not see. Stopping a session stops it for good until you ask again — coming back to the app won't restart it.")
            }
            .onAppear { refreshLaunchStatus() }

            Section {
                Toggle("Speak What Each Sound Means", isOn: $spokenCues)
                    .tint(AppAccent.color)
                Button {
                    guard !tourRunning else { return }
                    tourRunning = true
                    Task { @MainActor in
                        await AppStateProvider.shared?.audibleLifecycle?.playCueTour().value
                        tourRunning = false
                    }
                } label: {
                    Label(tourRunning ? "Playing the sounds…" : "Play the Sounds",
                          systemImage: "speaker.wave.2")
                }
                .disabled(tourRunning)
                // The button's job is to make sounds, so its accessible description has to say
                // what is about to happen rather than leave a blind user tapping into silence.
                .accessibilityHint("Plays each sound the assistant uses and says what it means.")
            } header: {
                Text("Session Sounds")
            } footer: {
                Text("While Blind Assistant is the selected live mode, the assistant plays a short sound — and says a short line — when it becomes ready, when the connection drops, when it comes back, and when a photo you asked for was taken. If the connection comes back without the camera, it says so rather than claiming it can see.\n\nSounds play whether or not VoiceOver is on. A cue that arrives while the assistant is talking waits for a gap; one that has stopped being true is dropped instead of played late.")
            }

            Section {
                NavigationLink {
                    ScanAssistSettingsView()
                } label: {
                    HStack {
                        Label("Scan Assist", systemImage: "arrow.left.and.right")
                        Spacer()
                        Text(scanAssistEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Scan Assist")
                    .accessibilityValue(scanAssistEnabled ? "On" : "Off")
                }
            } header: {
                Text("Scan Assist")
            } footer: {
                Text("Reminders to check one side — the left or right you choose — while you read or work at a table. Spoken or a gentle sound, on a timer you set, for a session that ends itself. No camera, and it never starts on its own.")
            }

            Section {
                NavigationLink {
                    FingerspellingSettingsView()
                } label: {
                    HStack {
                        Label("Fingerspelling", systemImage: "hands.sparkles")
                        Spacer()
                        Text(fingerspellingEnabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
                    // Name and state are one row, not two stops with a gap between them.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Fingerspelling")
                    .accessibilityValue(fingerspellingEnabled ? "On" : "Off")
                }
            } header: {
                Text("Sign Language")
            } footer: {
                Text("Recognizes ASL fingerspelling through the glasses camera and speaks the words — on-device, independent of Reading Accessibility.")
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

#Preview {
    NavigationStack {
        AccessibilitySettingsView()
    }
}
