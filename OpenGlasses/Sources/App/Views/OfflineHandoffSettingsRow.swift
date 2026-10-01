import SwiftUI

/// "Keep talking without signal" (Plan GE P1), in Settings → AI & Personality. It works with or
/// without glasses, so it lives with the other intelligence settings rather than the glasses
/// section.
///
/// The setting only does anything with an on-device model installed, so without one the row says
/// so and leads to the download instead of offering a switch that would change nothing.
struct OfflineHandoffSettingsRow: View {
    @ObservedObject var appState: AppState
    @State private var enabled = Config.offlineHandoffEnabled
    @State private var hasOnDeviceModel = false

    static let title = "Keep Talking Without Signal"
    static let info = "When the connection drops, Avenkin carries on with the on-device model — with fewer tools and a shorter memory of the conversation — and tells you once. When a steady connection is back it returns to your cloud model by itself and lets it know which answers came from the phone. If the phone is locked, a question that needs thinking is held and answered when you're back online. To check the connection is back, Avenkin sends an empty request to your AI provider's own address; nothing you said goes with it."

    var body: some View {
        Group {
            if hasOnDeviceModel {
                InfoToggle(title: Self.title, isOn: $enabled, info: Self.info)
                    .onChange(of: enabled) { _, newValue in
                        Config.offlineHandoffEnabled = newValue
                    }
            } else {
                NavigationLink {
                    LocalModelManagerView()
                        .environmentObject(appState)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep Talking Without Signal")
                        Text("Download an on-device model to keep talking when the signal drops.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            hasOnDeviceModel = OfflineHandoffAvailability.current().hasAnyModel
            enabled = Config.offlineHandoffEnabled
        }
    }
}
