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
    @AppStorage("accessibilityReadingLevel") private var readingLevel: Int = ReadingProfile.Level.adult.rawValue
    @AppStorage("accessibilityReadingLanguage") private var language: String = ReadingProfile.preferredLanguage

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
            } footer: {
                Text("Reads text through the glasses camera using on-device OCR. When enabled, the `reading_assist` tool can read aloud, simplify, translate, or define text you're looking at. Images never leave your device.")
            }

            if enabled {
                Section {
                    Picker("Reading Level", selection: $readingLevel) {
                        ForEach(ReadingProfile.Level.allCases, id: \.rawValue) { level in
                            Text("\(level.rawValue) — \(level.audienceDescription.capitalizedFirst)")
                                .tag(level.rawValue)
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
                Text("Describes the space around you as it changes, for moving through somewhere unfamiliar. Watching is silent — descriptions build up so questions about what you're looking at are answered instantly. Speaking them aloud is a separate switch.\n\nNot continuous coverage: descriptions are generated on this device, which can't run while the app is in the background or the phone is locked. Narration stops there and says so out loud. It also needs glasses that stream live video — on glasses that only take photos it can't run at all.")
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
                }
            } header: {
                Text("Sign Language")
            } footer: {
                Text("Recognizes ASL fingerspelling through the glasses camera and speaks the words — on-device, independent of Reading Accessibility.")
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
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
