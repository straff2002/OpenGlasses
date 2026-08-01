import SwiftUI

/// Settings for turn-by-turn walking navigation (Plan CA).
struct NavigationSettingsView: View {
    @State private var units = Config.navigationUnits
    @State private var voiceCues = Config.navigationVoiceCues

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
                Text("Say \u{201C}navigate to \u{2026}\u{201D} to start walking directions — each turn shows in-lens and is spoken as you approach it. Walking routes only; driving stays with CarPlay. Routing needs a network connection.")
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
                Text("Recents also appear in the glasses menu under Navigate.")
            }
        }
        .navigationTitle("Navigation")
    }
}
