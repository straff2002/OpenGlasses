import SwiftUI

/// Settings → Everyday → Health & Fitness → Health: what Avenkin reads from Apple Health, and the
/// summary kept on this phone for locked-phone answers (Plan GI). The switches for summaries and
/// for sharing with the AI are the group's (Plan KH P2).
struct HealthSettingsView: View {
    @AppStorage("healthVaultAIEnabled") private var healthVaultAIEnabled = true
    @ObservedObject private var adminGate = AdminGate.shared
    @State private var authorization: HealthAuthorizationState?
    @State private var savedAt: Date?
    @State private var requesting = false

    private let cache = HealthSummaryCache()

    var body: some View {
        Form {
            Section {
                ForEach(HealthSummaryReadType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: icon(for: type))
                }
                accessRow
            } header: {
                Text("What Avenkin reads")
            } footer: {
                Text("Read only. Avenkin never writes heart rate, sleep or steps to Apple Health. The fitness coach separately reads your workouts and saves the workouts you log.")
            }

            if adminGate.presentation(.row(in: .everyday)).isShown && adminGate.presentation(.tool("health_vault")).isShown {
                Section {
                    InfoToggle(
                        title: "AI Access to Health Vault",
                        isOn: $healthVaultAIEnabled,
                        info: "When off, the assistant cannot look up or edit your Health Vault directly. Existing records stay on this phone. Apple Health summaries and their sharing setting are controlled separately, under Health & Fitness."
                    )
                    .disabled(!adminGate.presentation(.row(in: .everyday)).isEditable || !adminGate.presentation(.tool("health_vault")).isEditable)
                }
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
