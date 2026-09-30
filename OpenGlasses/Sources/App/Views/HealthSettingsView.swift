import SwiftUI

/// Settings → Privacy → Health: what Avenkin reads from Apple Health, whether the AI may see it,
/// and the summary kept on this phone for locked-phone answers (Plan GI).
struct HealthSettingsView: View {
    @State private var shareWithAI = Config.shareHealthDataWithAI
    @State private var summariesEnabled = Config.healthSummariesEnabled
    @State private var authorization: HealthAuthorizationState?
    @State private var savedAt: Date?
    @State private var requesting = false

    private let cache = HealthSummaryCache()

    var body: some View {
        Form {
            Section {
                ForEach(HealthSummaryReadType.allCases, id: \.self) { type in
                    Label(LocalizedStringKey(type.displayName), systemImage: icon(for: type))
                }
                accessRow
            } header: {
                Text("What Avenkin reads")
            } footer: {
                Text("Read only. Avenkin never writes heart rate, sleep or steps to Apple Health. The fitness coach separately reads your workouts and saves the workouts you log.")
            }

            Section {
                Toggle("Health Summaries", isOn: $summariesEnabled)
                    .onChange(of: summariesEnabled) { _, newValue in
                        Config.healthSummariesEnabled = newValue
                    }
            } footer: {
                Text("Answers questions like “how did I sleep?” or “what's my heart rate?” with one short sentence of numbers. It reports; it never interprets or gives medical advice.")
            }

            Section {
                InfoToggle(
                    title: "Share Health Data with AI",
                    isOn: $shareWithAI,
                    info: "Off by default. While it's off and you use a cloud AI model, Avenkin speaks a health summary to you itself, using an on-device voice, and the AI provider only learns that you asked — never the numbers. Turn it on to let your AI provider (Anthropic, OpenAI, Google, etc.) see the summary so it can answer follow-ups like “is that usual for me?”, and so the fitness coach can discuss your workout history. With an on-device model the numbers never leave your phone either way. Medical Compliance mode always keeps them from the AI."
                )
                .onChange(of: shareWithAI) { _, newValue in
                    Config.setShareHealthDataWithAI(newValue)
                }
            } header: {
                Text("AI")
            } footer: {
                Text("When this is on, replies that include health numbers are spoken with your chosen voice, which may be a cloud voice.")
            }

            Section {
                if let savedAt {
                    LabeledContent("Last saved") {
                        Text(savedAt, format: .dateTime.hour().minute().weekday(.abbreviated))
                    }
                    Button("Clear Saved Summary", role: .destructive) {
                        cache.clear()
                        self.savedAt = nil
                    }
                } else {
                    Text("Nothing saved")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Stored on this phone")
            } footer: {
                Text("Apple Health can't be read while your phone is locked, which is when you're most likely to ask from your glasses. So Avenkin keeps the last summary numbers — never the underlying samples — encrypted on this phone, out of backups, for up to 24 hours. A locked-phone answer says how old it is.")
            }
        }
        .navigationTitle("Health")
        .task { await refreshState() }
    }

    @ViewBuilder
    private var accessRow: some View {
        switch authorization {
        case .unavailable:
            Label("Apple Health isn't available on this device", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .notDetermined:
            Button {
                Task { await requestAccess() }
            } label: {
                Label("Allow Apple Health Access", systemImage: "heart.text.square")
            }
            .disabled(requesting)
        case .requested:
            Text("To change what Avenkin can read, open the Health app, then Sharing, Apps, Avenkin.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case nil:
            ProgressView()
        }
    }

    private func icon(for type: HealthSummaryReadType) -> String {
        switch type {
        case .heartRate: return "heart"
        case .restingHeartRate: return "heart.circle"
        case .sleepAnalysis: return "bed.double"
        case .stepCount: return "figure.walk"
        }
    }

    private func refreshState() async {
        authorization = await HealthKitSampleReader().authorizationState()
        savedAt = cache.load()?.newest
    }

    private func requestAccess() async {
        requesting = true
        defer { requesting = false }
        _ = await HealthKitSampleReader().requestAuthorization()
        await AppStateProvider.shared?.refreshHealthSummaryCache()
        await refreshState()
    }
}
