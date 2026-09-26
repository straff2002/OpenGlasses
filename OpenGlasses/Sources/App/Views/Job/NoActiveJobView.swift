import SwiftUI

/// The Job tab with no job open: which vault the next one would use, one large Start job button,
/// and every job that has been finished (Plan FO P2).
///
/// The past-job list is the index this user actually thinks in. The Chat tab lists conversations by
/// their first sentence, which is the wrong index for a technician looking for "the Lennox one on
/// Tuesday, job 1005".
struct NoActiveJobView: View {
    let empty: JobTabModel.NoJob
    let model: JobTabModel
    @Binding var search: String
    @Binding var typedReference: String
    let onStart: () -> Void
    let onOpenPastJob: (String) -> Void
    /// Reports asked for by voice and waiting for a thumb (Plan FO P3b). First on the screen,
    /// because a report nobody sent is the one thing a technician must not find out about a week
    /// later. Nil when nothing is waiting.
    var sendCard: JobSendQueueSection?
    /// Jobs ahead (Plan FO P3c), between starting one now and the ones already done.
    var upcoming: UpcomingJobsSection?
    /// Every job started on the chosen day, as one transcript file in the share sheet.
    var onExportDay: ((Date) -> Void)?
    /// The chosen day as a support report, reviewed before it is sent.
    var onReportDay: ((Date) -> Void)?

    @FocusState private var referenceFocused: Bool

    private var rows: [JobTabModel.PastJobRow] { model.pastJobs(matching: search) }

    var body: some View {
        List {
            sendCard
            vaultSection
            startSection
            upcoming
            pastJobsSection
        }
        .ogFormStyle()
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Search past jobs by number"))
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
            Text("New job")
        } footer: {
            Text("You can also just say it — \u{201C}start a job\u{201D} — and the number will be asked for and read back to you.")
        }
    }

    // MARK: - What has already been done

    @ViewBuilder
    private var pastJobsSection: some View {
        Section {
            if !model.hasPastJobs {
                Text("No finished jobs yet. Jobs you close appear here, newest first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else if rows.isEmpty {
                // The absence is about the search, not about the jobs — say which.
                Text("No past job matches that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { row in
                    Button { onOpenPastJob(row.id) } label: {
                        PastJobRowView(row: row)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.spoken)
                    .accessibilityHint("Opens the work record, its conversation, and Send report.")
                    .accessibilityAddTraits(.isButton)
                }
            }
            if let onExportDay, model.hasPastJobs {
                exportDayMenu(onExportDay)
            }
        } header: {
            Text("Past jobs")
        }
    }

    /// A menu of the days that have jobs, rather than a date picker that can land on a day with
    /// none. A menu, not a sheet, because the share sheet it leads to cannot open over a sheet.
    private func exportDayMenu(_ export: @escaping (Date) -> Void) -> some View {
        Menu {
            ForEach(model.transcriptDays) { entry in
                Menu {
                    Button("Transcript") { export(entry.day) }
                    if let onReportDay {
                        Button("Support report with troubleshooting details") { onReportDay(entry.day) }
                    }
                } label: {
                    Text(verbatim: Self.dayLabel(entry.day, jobCount: entry.jobCount))
                }
            }
        } label: {
            Text("Export a day…")
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
        .accessibilityHint("Choose a day, then a transcript of that day's jobs or a support report with the details of each AI turn. Nothing leaves the phone until you choose where it goes.")
    }

    static func dayLabel(_ day: Date, jobCount: Int) -> String {
        let date = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        return jobCount == 1 ? "\(date) · 1 job" : "\(date) · \(jobCount) jobs"
    }
}

/// One finished job in the list. The job number leads, because that is what it is filed under, and
/// a job that never had one says so rather than rendering a blank line.
struct PastJobRowView: View {
    let row: JobTabModel.PastJobRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.jobNumber)
                    .font(.headline)
                    .foregroundStyle(row.hasJobNumber ? Color.primary : Color.secondary)
                Spacer(minLength: 8)
                Text(row.outcomeLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(Color.secondary)
            }
            Text(row.dateLine)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            Text(detailLine)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        }
        .padding(.vertical, 4)
    }

    private var detailLine: String {
        [row.equipment ?? row.vaultName, row.billingLine].joined(separator: " · ")
    }
}
