import SwiftUI

/// Advanced controls for the Content-Aware Frame Gate (Plan AT). Lets a power user
/// turn on dropping near-duplicate camera frames before the live LLM and tune the
/// similarity threshold + heartbeat without a rebuild. Off by default.
struct LiveVisionSettingsView: View {
    @State private var enabled = Config.frameDedupEnabled
    @State private var threshold = Double(Config.frameDedupHammingThreshold)
    @State private var heartbeat = Config.frameDedupHeartbeatSeconds

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LLMImageSettingsView()
                } label: {
                    HStack {
                        Label("Image Compression", systemImage: "photo.badge.arrow.down")
                        Spacer()
                        Text(Config.llmImagePreset.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Resize and compress photos before they're sent to the AI for description — keeps context smaller while preserving readable detail.")
            }

            Section {
                Toggle("Drop near-duplicate frames", isOn: $enabled)
                    .onChange(of: enabled) { _, v in Config.setFrameDedupEnabled(v) }
            } footer: {
                Text("When on, the glasses stop sending the live AI a new frame while the scene hasn't visibly changed — saving bandwidth and tokens. Distinct views still flow.")
            }

            if enabled {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Similarity threshold")
                            Spacer()
                            Text("\(Int(threshold))").foregroundStyle(.secondary)
                        }
                        Slider(value: $threshold, in: 1...12, step: 1)
                            .onChange(of: threshold) { _, v in Config.setFrameDedupHammingThreshold(Int(v)) }
                    }
                    Stepper("Heartbeat: \(Int(heartbeat))s", value: $heartbeat, in: 5...30, step: 1)
                        .onChange(of: heartbeat) { _, v in Config.setFrameDedupHeartbeatSeconds(v) }
                } header: {
                    Text("Tuning")
                } footer: {
                    Text("Higher threshold drops more (treats more frames as \"the same scene\"). Heartbeat forces a fresh frame through after this many seconds even if nothing changed, so the AI's view can't go stale. Defaults: 4 and 12s.")
                }
            }
        }
        .navigationTitle("Live Vision")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }
}
