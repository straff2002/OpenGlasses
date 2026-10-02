import SwiftUI

/// The home screen's job-day card (Plan HB): shown whenever Field Assist mode is on, in place of
/// My Day's card. Collapsed, one header row — "Today" and the day in a line or two; the chevron
/// opens it in place; tapping the card itself opens the whole day full screen.
///
/// Thin: the rows, their order, the empty day and the summary line are `JobDayComposer`'s, and the
/// facts are gathered by `JobDayFeed`. The card's height is measured with the rest of the surface
/// above the dock (Plan GW), so the panel takes back what the card gives up, on the same curve.
struct JobDayHomeCard: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: JobDayFeed
    /// Fold My Day's own items in below the job admin (`HomeDayCard.jobDay(showsPersonal:)`).
    let showsPersonal: Bool
    /// The mic is open: the header only, like My Day's compact card.
    let compact: Bool
    /// Opens the full-screen day. Presented by the tab, not the card: the card yields its place to
    /// every turn, and the day view must not go with it.
    let onOpenDay: () -> Void

    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Collapsed is the resting state and the default; the wearer's choice is remembered.
    @AppStorage("jobDayCollapsed") private var isCollapsed = true

    /// How much of the day the open card draws before "Open your day" carries the rest.
    /// Kept small: the open card shares the zone with the grid, and the full day is one tap away.
    private static let cardJobs = 3
    private static let cardTodos = 2
    private static let cardPersonal = 2

    private var day: JobDay { feed.day }

    var body: some View {
        OGCard {
            VStack(spacing: 0) {
                header
                if !isCollapsed && !compact {
                    Rectangle()
                        .fill(OGTheme.hairline)
                        .frame(height: 0.5)
                        .accessibilityHidden(true)
                    openContent
                }
            }
        }
        .animation(DockGridMetrics.heightSettle, value: isCollapsed)
        .padding(.horizontal, 16)
        .onAppear { feed.showsPersonal = showsPersonal }
        .onChange(of: showsPersonal) { _, shows in feed.showsPersonal = shows }
        .task(id: showsPersonal) {
            guard showsPersonal, case .idle = appState.myDayService.state else { return }
            _ = await appState.myDayService.refresh(channel: nil)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Button { onOpenDay() } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                layout {
                    Label("Today", systemImage: ModesTabPresentation.fieldAssistSymbol)
                        .font(.headline)
                        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                        .fixedSize()
                    Text(day.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(day.spokenSummary)
            .accessibilityHint("Opens your day.")
            .accessibilityAddTraits(.isButton)

            if !compact {
                Button {
                    isCollapsed.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                        .frame(width: OGMetrics.minTouchTarget, height: OGMetrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityLabel(isCollapsed ? "Expand today's jobs" : "Collapse today's jobs")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Open, in place

    private var openContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if day.isEmptyDay {
                cardLine(symbol: "calendar", title: "No jobs today",
                         detail: day.next.map { "Next: \($0.whenText) · \($0.title)" })
            } else {
                ForEach(day.jobs.prefix(Self.cardJobs)) { job in
                    cardLine(symbol: JobDayRowStyle.symbol(job.status), title: job.title,
                             detail: [job.timeText, job.site, job.status.label]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                             warn: job.status == .overdue)
                }
            }

            if !day.todos.isEmpty {
                groupLabel("Still to do")
                ForEach(day.todos.prefix(Self.cardTodos)) { todo in
                    cardLine(symbol: todo.kind.symbol, title: todo.title, detail: todo.detail,
                             warn: todo.kind == .reportFailed)
                }
            }

            if day.showsPersonal && !day.personal.isEmpty {
                groupLabel("My Day")
                let shown = Array(day.personal.prefix(Self.cardPersonal))
                ForEach(shown) { item in
                    cardLine(symbol: JobDayRowStyle.symbol(item.kind), title: item.title, detail: item.detail)
                }
                // Apple requires its Weather credit wherever WeatherKit data is displayed.
                if shown.contains(where: { $0.kind == .weather }) {
                    WeatherAttributionView()
                        .padding(.leading, 30)
                }
            }

            let hidden = max(0, day.jobs.count - Self.cardJobs) + max(0, day.todos.count - Self.cardTodos)
                + (day.showsPersonal ? max(0, day.personal.count - Self.cardPersonal) : 0)
            Button { onOpenDay() } label: {
                Text(hidden > 0 ? "Open your day (\(hidden) more)" : "Open your day")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityHint("Shows every job and everything still to do.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { onOpenDay() }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    private func cardLine(symbol: String, title: String, detail: String?, warn: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(warn ? OGTheme.warnLabel : OGTheme.tintedAccentLabel(accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(warn ? OGTheme.warnLabel : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your day.")
        .accessibilityAction { onOpenDay() }
    }
}

/// The whole day, full screen (Plan HB). Every row opens its own screen; Done comes back.
struct JobDayView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: JobDayFeed
    /// A row that leaves this view — the Jobs tab, or a report's composer.
    let onLeave: (JobDayDestination) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    private enum Route: Hashable {
        case destination(JobDayDestination)
        case transcript(threadId: String)
    }

    private var day: JobDay { feed.day }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if day.isEmptyDay {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No jobs today").font(.headline)
                            Text(day.next == nil ? "Nothing is scheduled." : "Your next job is below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        if let next = day.next {
                            row(symbol: "calendar", title: next.title, detail: "Next: \(next.whenText)",
                                destination: next.destination)
                        }
                    }
                } else {
                    Section("Jobs") {
                        ForEach(day.jobs) { job in
                            row(symbol: JobDayRowStyle.symbol(job.status), title: job.title,
                                detail: [job.timeText, job.site].compactMap { $0 }.filter { !$0.isEmpty }
                                    .joined(separator: " · "),
                                status: job.status.label, warn: job.status == .overdue,
                                destination: job.destination)
                        }
                    }
                }

                if !day.todos.isEmpty {
                    Section("Still to do") {
                        ForEach(day.todos) { todo in
                            row(symbol: todo.kind.symbol, title: todo.title, detail: todo.detail,
                                warn: todo.kind == .reportFailed, destination: todo.destination)
                        }
                    }
                }

                if day.showsPersonal {
                    Section("My Day") {
                        if day.personal.isEmpty {
                            Text("Nothing on your own list right now.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(day.personal) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    OGIconTile(systemName: JobDayRowStyle.symbol(item.kind))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.body)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if let detail = item.detail {
                                            Text(detail).font(.footnote).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if item.kind == .weather {
                                            WeatherAttributionView().padding(.top, 2)
                                        }
                                    }
                                }
                                .frame(minHeight: OGMetrics.minTouchTarget)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .ogFormStyle()
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                destinationView(route)
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ route: Route) -> some View {
        switch route {
        case .destination(.upcomingJob(let id)):
            let vaultId = Config.fieldAssistDefaultVaultId
            UpcomingJobView(store: appState.upcomingJobs, flow: appState.guidedJobFlow, jobId: id,
                            jobOpen: FieldSessionService.shared.activeSession.map {
                                $0.endedAt == nil && $0.outcome != .cancelled } ?? false,
                            vaultName: VaultRegistry.shared.manifest(id: vaultId)?.name ?? vaultId,
                            vaultUnlocked: VaultRegistry.shared.isUnlocked(vaultId),
                            onStarted: { _ in onLeave(.openJob) })
        case .destination(.pastJob(let sessionId)):
            PastJobView(sessionId: sessionId,
                        model: JobTabModel(host: FieldSessionService.shared, flow: appState.guidedJobFlow),
                        onOpenTranscript: { path.append(.transcript(threadId: $0)) })
        case .transcript(let threadId):
            JobTranscriptView(threadId: threadId)
        case .destination(.openJob), .destination(.send):
            EmptyView()
        }
    }

    private func go(_ destination: JobDayDestination) {
        switch destination {
        case .upcomingJob, .pastJob:
            path.append(.destination(destination))
        case .openJob, .send:
            onLeave(destination)
        }
    }

    private func row(symbol: String, title: String, detail: String?, status: String? = nil,
                     warn: Bool = false, destination: JobDayDestination) -> some View {
        Button { go(destination) } label: {
            HStack(alignment: .top, spacing: 12) {
                OGIconTile(systemName: symbol)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(warn ? OGTheme.warnLabel : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let status {
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(warn ? OGTheme.warnLabel : .secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: OGMetrics.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail, status].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}

/// The day's symbols, shared by the card and the full view.
enum JobDayRowStyle {
    static func symbol(_ status: JobDay.Job.Status) -> String {
        switch status {
        case .scheduled: return "clock"
        case .overdue: return "exclamationmark.circle"
        case .inProgress: return "briefcase.fill"
        case .paused: return "pause.circle"
        case .done: return "checkmark.circle"
        }
    }

    static func symbol(_ kind: MyDayKind) -> String {
        switch kind {
        case .event: return "calendar"
        case .leaveBy: return "location.fill"
        case .preparation: return "checkmark.seal"
        case .reminder: return "checklist"
        case .update: return "bell.badge"
        case .weather: return "cloud.sun"
        }
    }
}
