import SwiftUI

/// The Jobs tab's first page (Plan HC): every job, and Add new job.
///
/// Top to bottom: reports waiting for a thumb (Plan FO P3b — first, because a report nobody sent is
/// the one thing a technician must not find out about a week later), the open job, Add new job,
/// the jobs scheduled, the ones finished this week with what is still owed on them, and the older
/// ones folded away. Every decision — the sections, their order, the badges, the empty list — is
/// `JobListComposer`'s; this only draws it and says where a tap goes.
struct JobListView: View {
    let list: JobList
    /// Reports asked for by voice and waiting. Nil when nothing is waiting.
    var sendCard: JobSendQueueSection?
    /// A link that could not land, said once at the top.
    @Binding var notice: String?
    @Binding var search: String
    /// A new job asked for while one is open: the question.
    @Binding var openJobPrompt: OpenJobPrompt?
    let onOpen: (JobRoute) -> Void
    let onAdd: () -> Void
    let onAnswer: (OpenJobPrompt.Answer) -> Void
    /// Days with jobs, for "Export a day…".
    let transcriptDays: [JobTranscriptExport.Day]
    var onExportDay: ((Date) -> Void)?
    var onReportDay: ((Date) -> Void)?
    var onSendToday: (() -> Void)?

    /// Folded by default: older jobs are found by searching far more often than by scrolling.
    @State private var showsOlder = false
    @State private var olderPages = 0

    private var isSearching: Bool { list.results != nil }

    var body: some View {
        List {
            if let notice { noticeSection(notice) }
            sendCard
            if let results = list.results {
                resultsSection(results)
            } else if list.isEmpty {
                emptySection
            } else {
                if let open = list.open {
                    Section {
                        row(open)
                    } header: {
                        Text("Open job")
                    }
                }
                addSection
                if !list.scheduled.isEmpty {
                    Section {
                        ForEach(list.scheduled) { row($0) }
                    } header: {
                        Text("Scheduled")
                    }
                }
                if !list.recent.isEmpty {
                    Section {
                        ForEach(list.recent) { row($0) }
                    } header: {
                        Text("Recent")
                    } footer: {
                        Text(list.recentFooter)
                    }
                }
                if !list.older.isEmpty { olderSection }
            }
            toolsSection
        }
        .ogFormStyle()
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text("Search by job number, customer or machine"))
        .confirmationDialog(openJobPrompt?.title ?? "",
                            isPresented: Binding(get: { openJobPrompt != nil },
                                                 set: { if !$0 { openJobPrompt = nil } }),
                            titleVisibility: .visible, presenting: openJobPrompt) { prompt in
            Button(prompt.resumeTitle) { onAnswer(.resume) }
            Button(prompt.finishTitle) { onAnswer(.finishFirst) }
            Button(OpenJobPrompt.scheduleTitle) { onAnswer(.scheduleLater) }
            Button("Cancel", role: .cancel) { onAnswer(.cancel) }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    // MARK: - Sections

    private func noticeSection(_ text: String) -> some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss") { notice = nil }
                    .font(.callout)
                    .buttonStyle(.borderless)
            }
            .frame(minHeight: OGMetrics.minTouchTarget)
        }
    }

    private var addSection: some View {
        Section {
            Button(action: onAdd) {
                Label("Add new job", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            // Prominent while nothing is open — it is the thing to do; quieter beside an open job,
            // where it asks before it does anything.
            .modifier(AddButtonStyle(prominent: list.open == nil))
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint(list.open == nil
                               ? "Start a job now, or schedule one for later."
                               : "A job is open. You'll be asked whether to resume it, finish it, or schedule the new job for later.")
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(JobList.emptyTitle).font(.headline)
                Text(JobList.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            Button(action: onAdd) {
                Label("Add new job", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.ogProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityHint("Start a job now, or schedule one for later.")
        }
    }

    private func resultsSection(_ results: [JobList.Item]) -> some View {
        Section {
            if results.isEmpty {
                Text(JobList.noResults(search))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(results) { row($0) }
            }
        } header: {
            Text("Results")
        }
    }

    private var olderSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsOlder) {
                let page = JobListComposer.page(list.older, pages: olderPages)
                ForEach(page.shown) { row($0) }
                if page.remaining > 0 {
                    Button {
                        olderPages += 1
                    } label: {
                        Text("Show \(min(page.remaining, JobListComposer.olderPageSize)) more")
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    }
                    .accessibilityHint("\(page.remaining) older jobs are not shown yet.")
                }
            } label: {
                Text(list.olderTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.primary)
            }
        }
    }

    @ViewBuilder
    private var toolsSection: some View {
        if onSendToday != nil || (onExportDay != nil && !transcriptDays.isEmpty) {
            Section {
                if let onSendToday {
                    Button(action: onSendToday) {
                        Text("Send today's conversations…")
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    }
                    .accessibilityHint("Everything said today so far, in jobs and out of them, for support. You see it before anything is sent.")
                }
                if let onExportDay, !transcriptDays.isEmpty {
                    exportDayMenu(onExportDay)
                }
            } footer: {
                Text("Everything said today so far, for support. You read it before it's sent.")
            }
        }
    }

    /// A menu of the days that have jobs, rather than a date picker that can land on a day with
    /// none. A menu, not a sheet, because the share sheet it leads to cannot open over a sheet.
    private func exportDayMenu(_ export: @escaping (Date) -> Void) -> some View {
        Menu {
            ForEach(transcriptDays) { entry in
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

    // MARK: - A row

    private func row(_ item: JobList.Item) -> some View {
        Button {
            notice = nil
            onOpen(item.route)
        } label: {
            JobListRowView(item: item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.spoken)
        .accessibilityHint(Self.hint(item.route))
        .accessibilityAddTraits(.isButton)
    }

    static func hint(_ route: JobRoute) -> String {
        switch route {
        case .currentJob: return "Opens the job: its number, time, unit, work and Close job."
        case .pastJob: return "Opens the work record, its conversation, and Send report."
        case .upcomingJob: return "Opens the job's brief, directions and Start."
        case .transcript: return "Opens the conversation."
        }
    }
}

/// Prominent, or a plain list button. A modifier so the two share one label.
private struct AddButtonStyle: ViewModifier {
    let prominent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.ogProminent)
        } else {
            content
        }
    }
}

/// One job in the list. The title leads, because that is what the job is filed under; a job with
/// no number says so rather than rendering a blank line.
struct JobListRowView: View {
    let item: JobList.Item

    @Environment(\.appAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(item.title == JobTabModel.noJobNumber ? Color.secondary : Color.primary)
                Spacer(minLength: 8)
                Text(item.status.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(item.status == .overdue ? OGTheme.warnLabel : Color.secondary)
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = item.note {
                Label(note, systemImage: item.noteIsWarning ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(item.noteIsWarning ? OGTheme.warnLabel : Color.secondary)
            }
            // Overdue is already the status; the badges are what is still owed.
            ForEach(item.badges.filter { $0.kind != .overdue }) { badge in
                Label {
                    Text(badge.label)
                        .foregroundStyle(badge.isWarning ? OGTheme.warnLabel : Color.primary)
                } icon: {
                    Image(systemName: badge.symbol)
                        .foregroundStyle(badge.isWarning ? OGTheme.warnLabel : accent)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(.vertical, 4)
    }
}
