import SwiftUI

/// Settings for turn-by-turn walking navigation (Plan CA). The footers name only the surfaces a
/// turn really reaches (`WalkingTurnSurfaces`), so glasses-free use never reads as a lens promise.
struct NavigationSettingsView: View {
    @ObservedObject var glassesDisplay: GlassesDisplayService
    @State private var units = Config.navigationUnits
    @State private var voiceCues = Config.navigationVoiceCues

    private var turnSurfaces: WalkingTurnSurfaces {
        #if AVENKIN_PHONE_ONLY
        let inLens = false
        #else
        let inLens = Config.glassesDisplayEnabled
            && (glassesDisplay.hasDisplayCapability || Config.hudMirrorEnabled)
        #endif
        return WalkingTurnSurfaces(voiceCues: voiceCues, inLens: inLens)
    }

    var body: some View {
        Form {
            Section {
                Picker("Units", selection: $units) {
                    ForEach(NavigationUnits.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: units) { _, newValue in
                    Config.navigationUnits = newValue
                }
                Toggle("Voice Cues", isOn: $voiceCues)
                    .onChange(of: voiceCues) { _, newValue in
                        Config.navigationVoiceCues = newValue
                    }
            } footer: {
                Text(turnSurfaces.footer)
            }

            Section {
                if Config.recentDestinations.isEmpty {
                    Text("No recent destinations yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Config.recentDestinations, id: \.self) { name in
                        Text(name)
                    }
                    Button("Clear Recents", role: .destructive) {
                        Config.recentDestinations = []
                    }
                }
            } header: {
                Text("Recent Destinations")
            } footer: {
                if let recentsFooter = turnSurfaces.recentsFooter {
                    Text(recentsFooter)
                }
            }
        }
        .navigationTitle("Navigation")
        .onAppear { glassesDisplay.deviceSupportsDisplay() }
        .ogFormStyle()
    }
}
