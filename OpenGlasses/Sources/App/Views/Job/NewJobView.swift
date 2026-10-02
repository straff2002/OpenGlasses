import SwiftUI

/// The page "Add new job" opens when no job is open (Plan HC; the empty state of Plan FO P2's tab):
/// which vault the job would use, one large Start job button with an optional number, and a way to
/// schedule a job for later instead.
///
/// It is the open job's page with no job in it (`JobRoute.currentJob`): starting a job here turns
/// this page into that job in place, exactly as the tab always behaved.
struct NewJobView: View {
    let empty: JobTabModel.NoJob
    @Binding var typedReference: String
    let onStart: () -> Void
    /// Add a job ahead — one not being started now.
    let onSchedule: () -> Void

    @FocusState private var referenceFocused: Bool

    var body: some View {
        List {
            vaultSection
            startSection
            scheduleSection
        }
        .ogFormStyle()
    }

    // MARK: - The vault a job would run against

    private var vaultSection: some View {
        Section {
            // The default vault is chosen in one place — Field Assist settings — and this links
            // there rather than growing a second picker that could disagree with it.
            NavigationLink {
                FieldAssistSettingsView()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vault in use")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        Text(empty.vaultName)
                            .font(.headline)
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                    Text("Change")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
                .padding(.vertical, 2)
            }
            .accessibilityLabel("Vault in use, \(empty.vaultName)")
            .accessibilityHint("Opens Field Assist settings, where the default vault is chosen.")
        } footer: {
            Text("The manuals and procedures a new job is grounded in. A job keeps the vault it started on until you finish it.")
        }
    }

    // MARK: - Starting one

    private var startSection: some View {
        Section {
            TextField(text: $typedReference) {
                Text("Job number (optional)")
            }
            .focused($referenceFocused)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { referenceFocused = false }
            .accessibilityLabel("Job number")
            .accessibilityHint("Optional. Leave it empty and you'll be asked for it out loud once the job starts.")

            Button(action: onStart) {
                Text("Start job")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .disabled(!empty.canStart)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint(typedReference.isEmpty
                               ? "Starts a job on \(empty.vaultName). You'll be asked for the job number."
                               : "Starts a job on \(empty.vaultName), filed under \(typedReference).")

            if let reason = empty.startBlockedReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
            }
        } header: {
            Text("Start now")
        } footer: {
            Text("You can also just say it — \u{201C}start a job\u{201D} — and the number will be asked for and read back to you.")
        }
    }

    // MARK: - Or later

    private var scheduleSection: some View {
        Section {
            Button(action: onSchedule) {
                Label(OpenJobPrompt.scheduleTitle, systemImage: "calendar.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Adds a job you haven't started yet to Scheduled, with its site and booking.")
        } header: {
            Text("Later")
        } footer: {
            Text("You can also say \u{201C}next job: 1007, no heat, Smith Street\u{201D}, or open a job file the office emailed you.")
        }
    }
}
