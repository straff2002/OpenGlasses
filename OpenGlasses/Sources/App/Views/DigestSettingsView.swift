import SwiftUI

/// Settings for the notification digest (Plan BZ) — "what's new" composed from OpenGlasses'
/// own event streams. First-party sources only: iOS exposes no third-party notifications and
/// the glasses firmware no ANCS hook, so there is deliberately no mirroring toggle to find here.
struct DigestSettingsView: View {
    @State private var enabled = Config.digestEnabled
    @State private var maxItems = Config.digestMaxItems
    @State private var delivery = Config.digestDelivery
    @State private var autoSurface = Config.digestAutoSurfaceOnConnect

    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Notification Digest", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        Config.digestEnabled = newValue
                    }
            } footer: {
                Text("Say \u{201C}what's new\u{201D} (or pick What's new in the HUD menu) for one ranked glance of pending calendar, location, and agent notifications — instead of one-at-a-time interruptions.")
            }

            Section {
                Stepper("Lines: \(maxItems)", value: $maxItems, in: 1...6)
                    .onChange(of: maxItems) { _, newValue in
                        Config.digestMaxItems = newValue
                    }
                Picker("Delivery", selection: $delivery) {
                    ForEach(DigestDelivery.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: delivery) { _, newValue in
                    Config.digestDelivery = newValue
                }
                Toggle("Show on Reconnect", isOn: $autoSurface)
                    .onChange(of: autoSurface) { _, newValue in
                        Config.digestAutoSurfaceOnConnect = newValue
                    }
            } header: {
                Text("Glance")
            } footer: {
                Text("Show on Reconnect flashes the digest once when the glasses reconnect and something urgent is pending — never while you're away, and never in power reserve.")
            }

            Section {
                Button("Clear Pending Items", role: .destructive) {
                    appState.notificationDigest.clearAll()
                }
            } footer: {
                Text("Items expire on their own: low priority after 30 minutes, medium after 2 hours, and anything dismissed or shown \u{201C}enough\u{201D} is retired.")
            }
        }
        .navigationTitle("Digest")
    }
}
