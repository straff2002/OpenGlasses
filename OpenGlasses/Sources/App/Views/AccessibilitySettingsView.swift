import SwiftUI

/// Settings UI for the Accessibility Tier (A1 Reading Accessibility): master toggle, default
/// reading level, and preferred translation language. These defaults feed the `reading_assist`
/// tool when the user doesn't specify them per request.
@MainActor
struct AccessibilitySettingsView: View {
    @AppStorage("accessibilityModeEnabled") private var enabled: Bool = false
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
