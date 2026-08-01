import SwiftUI

/// Settings for the display backend (Plan AH): Ray-Ban Display (DAT, default) or EVEN
/// Realities G2 over BLE. The backend choice governs the DISPLAY only — camera and audio
/// keep running on their own services, so pairing Meta glasses for camera while an EVEN G2
/// renders the HUD is a supported hybrid.
struct EvenDisplaySettingsView: View {
    @State private var backend = Config.displayBackend
    @StateObject private var scanner = EvenBLETransport()
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                Picker("HUD renders on", selection: $backend) {
                    ForEach(DisplayBackendChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .onChange(of: backend) { _, newValue in
                    Config.displayBackend = newValue
                }
            } footer: {
                Text("Which glasses render the in-lens HUD. Camera and voice are unaffected — Ray-Ban camera plus EVEN G2 display works together. Takes effect on the next HUD update.")
            }

            if backend == .evenG2 {
                Section {
                    pairedRow(title: "Left lens", id: Config.evenLeftPeripheralID)
                    pairedRow(title: "Right lens", id: Config.evenRightPeripheralID)
                    if Config.evenPairingConfigured {
                        Button("Forget Pairing", role: .destructive) {
                            Config.evenLeftPeripheralID = nil
                            Config.evenRightPeripheralID = nil
                        }
                    }
                } header: {
                    Text("Paired Lenses")
                } footer: {
                    Text("EVEN G2 lenses are two separate Bluetooth devices — pair both. One lens alone works in a degraded single-lens mode.")
                }

                Section {
                    Button(scanning ? "Stop Scanning" : "Scan for Lenses") {
                        scanning.toggle()
                        if scanning { scanner.startScan() } else { scanner.stopScan() }
                    }
                    ForEach(scanner.discovered, id: \.id) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Button("Left") { Config.evenLeftPeripheralID = device.id.uuidString }
                                .buttonStyle(.bordered)
                            Button("Right") { Config.evenRightPeripheralID = device.id.uuidString }
                                .buttonStyle(.bordered)
                        }
                    }
                    if scanning && scanner.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for \u{201C}Even G2\u{201D} devices\u{2026}")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("The EVEN protocol support is early: it is based on a community reconstruction and hasn't been validated against hardware yet. The display path stays inert until lenses are paired here.")
                }
            }
        }
        .navigationTitle("Display Backend")
        .onDisappear { scanner.stopScan() }
    }

    @ViewBuilder
    private func pairedRow(title: String, id: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(id == nil ? "Not paired" : "Paired")
                .foregroundStyle(id == nil ? .secondary : .primary)
        }
    }
}
