import SwiftUI

/// Settings › Devices & Privacy › Apple Watch (Plans GM, KS): what the phone shows on the wrist.
struct AppleWatchSettingsView: View {
    @State private var mapCards = Config.watchMapCards
    @State private var today = Config.watchTodayEnabled

    var body: some View {
        Form {
            Section {
                Picker("Maps on Your Watch", selection: $mapCards) {
                    ForEach(WatchMapCardsSetting.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .onChange(of: mapCards) { _, newValue in
                    Config.watchMapCards = newValue
                    WatchConnectivityManager.shared.sendStatusUpdate()
                }
            } footer: {
                Text(Self.footer(for: mapCards))
            }

            Section {
                Toggle("Today on Your Watch", isOn: $today)
                    .onChange(of: today) { _, newValue in
                        Config.watchTodayEnabled = newValue
                        let manager = WatchConnectivityManager.shared
                        manager.todayPublisher?.valueMayHaveChanged()
                        if newValue { manager.todayPublisher?.refreshIfDue() }
                    }
            } footer: {
                Text(today
                     ? "Your next few events and today\u{2019}s weather, from My Day, on your watch beside Now Playing. They go only to your own watch, over the connection between your iPhone and your watch. With Medical Compliance on, the watch shows times but no event names or places."
                     : "Nothing from your calendar or the weather is sent to your watch. Now Playing still works on the watch.")
            }
        }
        .navigationTitle("Apple Watch")
        .ogFormStyle()
    }

    private static func footer(for setting: WatchMapCardsSetting) -> LocalizedStringKey {
        switch setting {
        case .automatic:
            return "When you ask where you are, how far something is, or for places nearby, the answer also appears on your watch as a small map — silently, without a tap on the wrist. Tap Go on a place to start walking directions. Map tiles come from Apple Maps; with Medical Local Only on, the watch shows the name, distance and direction without a map."
        case .onlyWhenAsked:
            return "A map appears on your watch only when you ask for it — say \u{201C}show me on my watch\u{201D}. It arrives with one tap on the wrist. Map tiles come from Apple Maps; with Medical Local Only on, the watch shows the name, distance and direction without a map."
        case .never:
            return "Nothing spatial is sent to your watch. Answers are still spoken and shown on your phone."
        }
    }
}
