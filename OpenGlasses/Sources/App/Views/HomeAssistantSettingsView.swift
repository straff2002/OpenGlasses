import SwiftUI

/// Settings → Everyday → Home, Music & Messages → Home Assistant (Plan KH P2): the connection to a
/// Home Assistant server. Whether the assistant may use it is AI Smart Home Control, in the group.
struct HomeAssistantSettingsView: View {
    @State private var haURL: String = Config.homeAssistantURL
    @State private var haToken: String = Config.homeAssistantToken

    var body: some View {
        Form {
            Section {
                TextField("HA URL (e.g. http://192.168.1.100:8123)", text: $haURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onChange(of: haURL) { _, newValue in
                        Config.setHomeAssistantURL(newValue)
                    }
                    // Show the address as it will be used, scheme included.
                    .onSubmit { haURL = Config.homeAssistantURL }

                SecretInputField(placeholder: String(localized: "Long-Lived Access Token"), text: $haToken)
                    .onChange(of: haToken) { _, newValue in
                        Config.setHomeAssistantToken(newValue)
                    }
            } header: {
                Text("Home Assistant")
            } footer: {
                Text("Direct REST API control — works alongside or instead of HomeKit. Generate a token in HA → Profile → Security → Long-Lived Access Tokens.")
            }
        }
        .navigationTitle("Home Assistant")
        .ogFormStyle()
    }
}
