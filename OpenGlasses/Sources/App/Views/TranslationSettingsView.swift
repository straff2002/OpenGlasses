import SwiftUI

/// Settings for translated captions (Plan BY P2). Off by default — the cloud tier streams audio
/// to Google's Gemini API, so it requires an explicit opt-in and is unavailable under HIPAA mode.
struct TranslationSettingsView: View {
    @State private var enabled = Config.translationCaptionsEnabled
    @State private var targetLanguage = Config.translationTargetLanguage
    @State private var showOriginal = Config.translationShowOriginal
    @State private var twoWay = Config.translationTwoWayEnabled
    @State private var languageA = Config.translationLanguageA
    @State private var languageB = Config.translationLanguageB
    @State private var interpreter = Config.interpreterEnabled

    /// A live caption session must re-pick its backend when these settings change.
    var onBackendChange: () -> Void = {
        NotificationCenter.default.post(name: .captionBackendChanged, object: nil)
    }

    var body: some View {
        Form {
            if Config.hipaaMode {
                Section {
                    Label("Cloud tier disabled in HIPAA mode", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Cloud translation is hard-disabled while HIPAA mode is on, so clinical audio never leaves the device. The on-device tier (SenseVoice + Apple Translation) still works when installed.")
                }
            }

            Section {
                Toggle("Translate Captions", isOn: $enabled)
                    .disabled(Config.hipaaMode)
                    .onChange(of: enabled) { _, newValue in
                        Config.translationCaptionsEnabled = newValue
                        onBackendChange()
                    }
            } footer: {
                Text("Ambient captions render in your language while someone speaks another — \u{201C}they speak Spanish, you read English\u{201D}. When off, captions transcribe exactly as today.")
            }

            Section {
                Picker("Translate Into", selection: $targetLanguage) {
                    ForEach(TranslationLanguages.curated, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .onChange(of: targetLanguage) { _, newValue in
                    Config.translationTargetLanguage = newValue
                    onBackendChange()
                }
                Toggle("Show Original", isOn: $showOriginal)
                    .onChange(of: showOriginal) { _, newValue in
                        Config.translationShowOriginal = newValue
                    }
            } header: {
                Text("Language")
            } footer: {
                Text("Show Original adds the source-language words under each translated caption.")
            }

            Section {
                Toggle("Two-Way Conversation", isOn: $twoWay)
                    .onChange(of: twoWay) { _, newValue in
                        Config.translationTwoWayEnabled = newValue
                        onBackendChange()
                    }
                if twoWay || interpreter {
                    Picker("Your Language", selection: $languageA) {
                        ForEach(TranslationLanguages.curated, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .onChange(of: languageA) { _, newValue in
                        Config.translationLanguageA = newValue
                        onBackendChange()
                    }
                    Picker("Their Language", selection: $languageB) {
                        ForEach(TranslationLanguages.curated, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .onChange(of: languageB) { _, newValue in
                        Config.translationLanguageB = newValue
                        onBackendChange()
                    }
                }
            } header: {
                Text("Conversation Mode")
            } footer: {
                Text("For a bilingual exchange: the screen splits, each side's speech renders in the other's language, and the glasses display shows only the line addressed to you.")
            }

            Section {
                Toggle("Spoken Interpreter", isOn: $interpreter)
                    .disabled(Config.hipaaMode || PolicyEnvelope.isLocked(.interpreterEnabled))
                    .onChange(of: interpreter) { _, newValue in
                        Config.interpreterEnabled = newValue
                        interpreter = Config.interpreterEnabled
                    }
                ManagedSettingNote(key: .interpreterEnabled)
            } footer: {
                Text("Ask for a two-way translation and each of you hears the other in your own language: you in the glasses, them from the phone, held between you. It uses your Gemini API key and sends what you both say to Google. The other person hears that it's AI translation when it starts. Nothing either of you says is saved here.")
            }

            Section {
                if Config.isGeminiLiveConfigured {
                    Label("Using your Gemini API key", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Add a Gemini API key in AI Models to enable translation", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(OGTheme.warnLabel)
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("""
                Raw audio is streamed to Google's Gemini API for transcription and translation — \
                including the voices of anyone nearby, not just you. Many places \
                (two-party-consent jurisdictions) require everyone's consent before their speech \
                is recorded, and Google may retain or use audio under its own terms. Only enable \
                this where recording bystanders is lawful and acceptable.
                """)
            }

            Section {
                if OnDeviceASREngine.isCompiledIn {
                    Label(onDeviceModelReady ? "SenseVoice model installed" : "SenseVoice model not downloaded",
                          systemImage: onDeviceModelReady ? "checkmark.circle" : "arrow.down.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("On-device recognition not in this build", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("On-Device Tier")
            } footer: {
                Text("Offline (or in HIPAA mode), translation runs entirely on the phone: SenseVoice transcribes, Apple Translation translates. Download the SenseVoice model under Speech Recognition; Apple's language pairs download on first use. Lower quality than the cloud tier, zero audio egress.")
            }
        }
        .navigationTitle("Translation")
        .ogFormStyle()
    }

    private var onDeviceModelReady: Bool { ASRModelStore().isModelPresent }
}

extension Notification.Name {
    /// Posted when a settings change requires a live caption session to re-pick its backend
    /// (translation toggled, target language changed). Observed by `AppState`, which calls
    /// `AmbientCaptionService.reconfigureForModeChange()` — same teardown path the HIPAA
    /// toggle uses, so a live cloud stream dies deterministically.
    static let captionBackendChanged = Notification.Name("captionBackendChanged")
}
