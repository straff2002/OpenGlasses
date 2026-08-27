import SwiftUI

/// Manage teleprompter scripts and pacing, paste/type a new script, and (while running)
/// drive playback with a live on-phone mirror of the in-lens HUD — so the whole feature is
/// usable and verifiable without Display glasses.
struct TeleprompterSettingsView: View {
    @ObservedObject var service: TeleprompterService
    @ObservedObject var store: TeleprompterScriptStore

    @State private var mode: PacingMode = Config.teleprompterMode
    @State private var wpm: Double = Double(Config.teleprompterWPM)
    @State private var lead: Int = Config.teleprompterLead

    @State private var draftTitle = ""
    @State private var draftText = ""

    @State private var scanStatus = ""
    @State private var isScanning = false

    var body: some View {
        Form {
            if service.isActive {
                nowPlayingSection
            }
            pacingSection
            captureSection
            newScriptSection
            savedScriptsSection
            ingestionHintSection
        }
        .navigationTitle("Teleprompter")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
    }

    // MARK: - Camera capture (Phase 4)

    private var captureSection: some View {
        Section {
            Button {
                Task {
                    isScanning = true
                    scanStatus = await service.scanPage()
                    isScanning = false
                }
            } label: {
                Label(isScanning ? "Scanning…" : "Scan a page (camera)", systemImage: "doc.viewfinder")
            }
            .disabled(isScanning)

            if service.hasScannedPages {
                Text("\(service.scanPages) page\(service.scanPages == 1 ? "" : "s") captured")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    service.startScannedScript()
                } label: {
                    Label("Start from scan", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Save scan as script") { service.saveScannedScript() }
                Button("Clear scan", role: .destructive) { service.clearScan() }
            }

            if !scanStatus.isEmpty {
                Text(scanStatus).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Capture from camera")
        } footer: {
            Text("Point the glasses at a printed or written script and scan it. Repeat for multiple pages, then start.")
        }
    }

    // MARK: - Now playing

    private var nowPlayingSection: some View {
        Section("Now playing") {
            if let screen = service.currentScreen {
                HUDPreviewView(screen: screen)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            HStack(spacing: 12) {
                controlButton(service.isPaused ? "Resume" : "Pause",
                              systemImage: service.isPaused ? "play.fill" : "pause.fill") {
                    service.isPaused ? service.resume() : service.pause()
                }
                controlButton("Back", systemImage: "backward.fill") { service.back() }
                controlButton("Next", systemImage: "forward.fill") { service.advance() }
            }
            HStack(spacing: 12) {
                controlButton("Slower", systemImage: "tortoise.fill") { service.nudgeSpeed(faster: false) }
                controlButton("Faster", systemImage: "hare.fill") { service.nudgeSpeed(faster: true) }
                controlButton("Stop", systemImage: "stop.fill", role: .destructive) { service.stop() }
            }
        }
    }

    private func controlButton(_ title: String, systemImage: String,
                               role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
    }

    // MARK: - Pacing

    private var pacingSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(PacingMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .onChange(of: mode) { _, newValue in Config.setTeleprompterMode(newValue) }

            if mode != .voice {
                VStack(alignment: .leading) {
                    Text("Speed: \(Int(wpm)) WPM")
                    Slider(value: $wpm, in: Double(PacingSpeed.wpmRange.lowerBound)...Double(PacingSpeed.wpmRange.upperBound), step: 5)
                        .onChange(of: wpm) { _, newValue in
                            Config.setTeleprompterWPM(Int(newValue))
                            if service.isActive { service.setWPM(Int(newValue)) }
                        }
                }
            }

            Stepper("Lead: \(lead) line\(lead == 1 ? "" : "s")", value: $lead,
                    in: PacingSpeed.leadRange.lowerBound...PacingSpeed.leadRange.upperBound)
                .onChange(of: lead) { _, newValue in
                    Config.setTeleprompterLead(newValue)
                    if service.isActive { service.setLead(newValue) }
                }
        } header: {
            Text("Pacing")
        } footer: {
            Text(pacingFooter)
        }
    }

    private var pacingFooter: String {
        switch mode {
        case .audioPaced: return "Auto-advances by listening to what you read. Say \"faster\"/\"slower\", \"pause\", \"next\"/\"back\"."
        case .voice: return "No auto-advance — drive it with \"next\"/\"back\" by voice or the Neural Band."
        case .autoScroll: return "Scrolls at a fixed words-per-minute."
        }
    }

    // MARK: - New script

    private var newScriptSection: some View {
        Section("New script") {
            TextField("Title (optional)", text: $draftTitle)
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text("Paste or type your script…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
                TextEditor(text: $draftText)
                    .frame(minHeight: 120)
            }
            HStack {
                Button("Save") { saveDraft() }
                    .disabled(trimmedDraft.isEmpty)
                Spacer()
                Button("Save & Start") {
                    let saved = saveDraft()
                    if let saved { service.start(savedID: saved.id) }
                }
                .disabled(trimmedDraft.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var trimmedDraft: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func saveDraft() -> SavedScript? {
        guard !trimmedDraft.isEmpty else { return nil }
        let saved = store.add(title: draftTitle, text: draftText)
        draftTitle = ""
        draftText = ""
        return saved
    }

    // MARK: - Saved scripts

    private var savedScriptsSection: some View {
        Section("Saved scripts") {
            if store.scripts.isEmpty {
                Text("No saved scripts yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.scripts) { script in
                    Button {
                        service.start(savedID: script.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(script.title).foregroundStyle(.primary)
                                Text(script.text.prefix(60).replacingOccurrences(of: "\n", with: " "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "play.circle")
                        }
                    }
                }
                .onDelete { store.delete(at: $0) }
            }
        }
    }

    // MARK: - Ingestion hint

    private var ingestionHintSection: some View {
        Section {
            Label("Import from Apple Notes", systemImage: "square.and.arrow.down")
                .font(.subheadline)
            Text("In the Shortcuts app, chain *Find Notes → OpenGlasses: Add Teleprompter Script* to send a note straight in.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
