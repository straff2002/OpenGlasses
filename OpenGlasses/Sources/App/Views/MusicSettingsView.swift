import SwiftUI

/// Settings → Services → Music (Plan GS P2): where music plays by default, Apple Music access and
/// catalogue status, and which Home Assistant speakers Avenkin may use. A general setting, not a
/// glasses one — the phone and a speaker are enough.
struct MusicSettingsView: View {
    @State private var defaultProvider: MusicProviderID = Config.musicDefaultProvider
    @State private var defaultSpeaker: String = Config.musicDefaultSpeaker
    @State private var hiddenSpeakers: Set<String> = Set(Config.musicHiddenSpeakers)
    @State private var askWhichSpeaker: Bool = Config.musicAskWhichSpeaker

    @State private var access: MusicAccessStatus = .notDetermined
    @State private var catalogue: Bool?
    @State private var speakers: [HomeAssistantMediaPlayer] = []
    @State private var speakerMessage: String?
    @State private var loadingSpeakers = false

    private let homeAssistant = HomeAssistantRESTClient()

    var body: some View {
        Form {
            defaultSection
            appleMusicSection
            if homeAssistant.isConfigured {
                speakersSection
            }
            otherAppsSection
        }
        .navigationTitle("Music")
        .ogFormStyle()
        .task {
            await refreshAppleMusic()
            await loadSpeakers()
        }
    }

    // MARK: - Default

    private var defaultSection: some View {
        Section {
            Picker("Play Music On", selection: $defaultProvider) {
                Text("Apple Music").tag(MusicProviderID.appleMusic)
                Text("Home Assistant Speaker").tag(MusicProviderID.homeAssistant)
            }
            .onChange(of: defaultProvider) { _, value in Config.musicDefaultProvider = value }
        } footer: {
            if defaultProvider == .homeAssistant && !homeAssistant.isConfigured {
                Text("Home Assistant isn't set up, so music plays on your phone until you add it under Services.")
            } else {
                Text("Where \u{201C}play\u{201D}, \u{201C}pause\u{201D} and \u{201C}skip\u{201D} go when you don't name a speaker. Whatever is already playing is controlled first.")
            }
        }
    }

    // MARK: - Apple Music

    private var appleMusicSection: some View {
        Section {
            HStack {
                Text("Access")
                Spacer()
                Text(accessLabel).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if access == .authorized {
                HStack {
                    Text("Plays From")
                    Spacer()
                    Text(catalogueLabel).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if access == .notDetermined {
                Button("Allow Apple Music Access") {
                    Task {
                        access = await MusicKitCatalog().requestAuthorization()
                        await refreshAppleMusic()
                    }
                }
            } else if access == .denied {
                Button("Open iPhone Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } header: {
            Text("Apple Music")
        } footer: {
            Text("With an Apple Music subscription, Avenkin can play anything in the Apple Music catalogue: the words you ask for are sent to Apple to find the music, under Apple's privacy policy. Without one, it plays from the library on this phone. When Medical Local Only is on, only your library is searched.")
        }
    }

    private var accessLabel: String {
        switch access {
        case .authorized: return String(localized: "Allowed")
        case .notDetermined: return String(localized: "Not asked yet")
        case .denied: return String(localized: "Off")
        case .restricted: return String(localized: "Restricted")
        }
    }

    private var catalogueLabel: String {
        switch catalogue {
        case true?: return String(localized: "Full catalogue")
        case false?: return String(localized: "Your library")
        case nil: return String(localized: "Checking…")
        }
    }

    private func refreshAppleMusic() async {
        let catalog = MusicKitCatalog()
        access = catalog.authorizationStatus
        catalogue = access == .authorized ? await catalog.canPlayCatalogContent() : nil
    }

    // MARK: - Speakers

    private var speakersSection: some View {
        Section {
            if loadingSpeakers && speakers.isEmpty {
                Text("Finding speakers…").foregroundStyle(.secondary)
            } else if speakers.isEmpty {
                Text(speakerMessage ?? String(localized: "Home Assistant has no media players."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(speakers, id: \.entityId) { speaker in
                    Toggle(isOn: Binding(
                        get: { !hiddenSpeakers.contains(speaker.entityId) },
                        set: { available in
                            if available { hiddenSpeakers.remove(speaker.entityId) } else { hiddenSpeakers.insert(speaker.entityId) }
                            Config.musicHiddenSpeakers = hiddenSpeakers.sorted()
                            if !available, defaultSpeaker == speaker.entityId { setDefaultSpeaker("") }
                        })) {
                        Text(verbatim: speaker.name)
                    }
                }
                Picker("Default Speaker", selection: Binding(get: { defaultSpeaker }, set: setDefaultSpeaker)) {
                    Text("None").tag("")
                    ForEach(speakers.filter { !hiddenSpeakers.contains($0.entityId) }, id: \.entityId) { speaker in
                        Text(verbatim: speaker.name).tag(speaker.entityId)
                    }
                }
                Toggle("Ask Which Speaker When Unsure", isOn: $askWhichSpeaker)
                    .onChange(of: askWhichSpeaker) { _, value in Config.musicAskWhichSpeaker = value }
            }
        } header: {
            Text("Home Assistant Speakers")
        } footer: {
            Text("Say \u{201C}on the kitchen speaker\u{201D} to pick one. Commands go only to your own Home Assistant. A speaker Home Assistant connects to a streaming service plays through Home Assistant's own link to that service — Avenkin never signs in to it.")
        }
    }

    private func setDefaultSpeaker(_ entityId: String) {
        defaultSpeaker = entityId
        Config.musicDefaultSpeaker = entityId
    }

    private func loadSpeakers() async {
        guard homeAssistant.isConfigured else { return }
        loadingSpeakers = true
        defer { loadingSpeakers = false }
        do {
            speakers = try await homeAssistant.mediaPlayers()
            speakerMessage = nil
        } catch {
            speakerMessage = HomeAssistantMusicProvider.failureLine(error)
        }
    }

    // MARK: - Other apps

    private var otherAppsSection: some View {
        Section {
            Text("Avenkin can't control Spotify or other music apps directly. Your glasses' temple controls still work on whatever's playing, and a Home Assistant speaker can be your music provider.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Other Music Apps")
        }
    }
}
