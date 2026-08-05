import SwiftUI

/// Settings page for fingerspelling recognition (Plan CK): master toggle, model download
/// (the Kokoro/ASR downloadable-model pattern), and live session start/stop with the
/// forming word mirrored from the HUD.
@MainActor
struct FingerspellingSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("fingerspellingEnabled") private var enabled: Bool = false
    @StateObject private var downloader = FingerspellingModelDownloader()
    @ObservedObject private var session = FingerspellingSessionService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Fingerspelling", isOn: $enabled)
                    .tint(AppAccent.color)
                    .onChange(of: enabled) { _, nowEnabled in
                        if !nowEnabled { session.stop() }
                    }
            } footer: {
                Text("Reads American Sign Language fingerspelling through the glasses camera — the signer faces you, letters build into words, and committed words are spoken aloud and shown on the HUD. Recognition runs entirely on this device.")
            }

            if enabled {
                modelSection
                if downloader.state == .ready {
                    sessionSection
                }
            }
        }
        .navigationTitle("Fingerspelling")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { downloader.refreshState() }
    }

    // MARK: - Model download

    @ViewBuilder
    private var modelSection: some View {
        Section {
            switch downloader.state {
            case .ready:
                HStack {
                    Label("Recognition Model", systemImage: "cpu")
                    Spacer()
                    Text("Installed").foregroundStyle(.secondary)
                }
                Button("Remove Download", role: .destructive) {
                    session.stop()
                    downloader.deleteModel()
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading… \(Int(progress * 100))%")
                    ProgressView(value: progress)
                }
            case .verifying:
                HStack {
                    Text("Verifying download…")
                    Spacer()
                    ProgressView()
                }
            case .failed(let reason):
                Text(reason).foregroundStyle(.red).font(.footnote)
                downloadButton
            case .notDownloaded:
                downloadButton
            case .notConfigured:
                Text("No model repository configured.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("The recognizer and its landmark extractor download once (~32 MB) and then work offline.")
        }
    }

    private var downloadButton: some View {
        Button("Download Model (~32 MB)") {
            Task { await downloader.download() }
        }
    }

    // MARK: - Live session

    @ViewBuilder
    private var sessionSection: some View {
        Section {
            Button {
                if session.isActive {
                    session.stop()
                } else {
                    Task {
                        await session.startLive(camera: appState.cameraService,
                                                tts: appState.speechService,
                                                display: appState.glassesDisplay)
                    }
                }
            } label: {
                Label(session.isActive ? "Stop Recognizing" : "Start Recognizing",
                      systemImage: session.isActive ? "stop.circle.fill" : "hand.raised.fill")
            }

            if session.isActive {
                HStack {
                    Text("Reading")
                    Spacer()
                    Text(session.provisionalWord.isEmpty ? "…" : session.provisionalWord)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let word = session.lastCommittedWord {
                    HStack {
                        Text("Last word")
                        Spacer()
                        Text(word).foregroundStyle(.secondary)
                    }
                }
            }

            if let detail = session.statusDetail {
                Text(detail).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Live Recognition")
        } footer: {
            Text("Works best with the signer 1–2 m away, facing the camera, at a camera frame rate of 15 fps or higher (Settings › Look & Feel › Camera).")
        }
    }
}

#Preview {
    NavigationStack {
        FingerspellingSettingsView()
            .environmentObject(AppState())
    }
}
