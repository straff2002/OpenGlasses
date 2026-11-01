import SwiftUI

/// Settings → Everyday → Memory → Activity (Plan IW P2): what the assistant did for the wearer, a
/// day at a time — each row's time, what it served, and how it was authorised — with filters, a
/// link to the goal or conversation a row belongs to, and Clear. Thin over `ActivityScreenModel`.
///
/// The Developer panel's Debug Events are a different thing and stay where they are.
struct ActivityView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model: ActivityScreenModel
    @State private var confirmClear = false

    init(model: @autoclosure @escaping () -> ActivityScreenModel) {
        _model = StateObject(wrappedValue: model())
    }

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: $model.filter) {
                    ForEach(ActivityScreenModel.Filter.allCases) { filter in
                        Text(verbatim: filter.label).tag(filter)
                    }
                }
            } footer: {
                if model.showsTitlesOnly {
                    Text("Medical mode is on, so each entry keeps its title only.")
                }
            }

            if model.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(Self.recordsOnlyLine)
                    }
                }
            } else {
                let sections = model.sections
                if sections.isEmpty {
                    Section {
                        Text("Nothing of this kind in the last 14 days.")
                            .foregroundStyle(OGTheme.secondaryLabel)
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                        }
                    } header: {
                        Text(verbatim: Self.dayTitle(section.day))
                    }
                }
                Section {
                    Button("Clear activity", role: .destructive) { confirmClear = true }
                } footer: {
                    Text(Self.recordsOnlyLine)
                }
            }
        }
        .navigationTitle("Activity")
        .ogFormStyle()
        .confirmationDialog("Clear all activity?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive) { model.clear() }
        } message: {
            Text("This removes the record of what the assistant did. It doesn't undo anything.")
        }
    }

    /// What the trail is, and what it never holds.
    static let recordsOnlyLine: LocalizedStringKey =
        "This lists what the assistant did for you — things added, sent, held for your OK or refused — over the last 14 days. It never records what you said or what was looked up."

    static func dayTitle(_ day: ActivityScreenModel.Day) -> String {
        switch day {
        case .today: return String(localized: "Today", comment: "Activity screen day heading.")
        case .yesterday: return String(localized: "Yesterday", comment: "Activity screen day heading.")
        case .earlier(let date):
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
    }

    @ViewBuilder
    private func rowView(_ row: ActivityScreenModel.Row) -> some View {
        switch row.destination {
        case .goal(let id):
            NavigationLink {
                GoalPage(goalID: id)
            } label: {
                rowContent(row)
            }
            .accessibilityHint(Text("Opens the goal."))
        case .thread(let id):
            NavigationLink {
                ChatThreadView(threadId: id)
                    .environmentObject(appState)
            } label: {
                rowContent(row)
            }
            .accessibilityHint(Text("Opens the conversation it belongs to."))
        case nil:
            rowContent(row)
        }
    }

    private func rowContent(_ row: ActivityScreenModel.Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OGIconTile(systemName: row.systemImage, muted: row.outcome != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: row.title)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let goal = row.goalTitle {
                    Text("For: \(goal)")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: ([row.at.formatted(date: .omitted, time: .shortened), row.authorisation]
                                + [row.outcome].compactMap { $0 }).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(OGTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

extension ActivityScreenModel {
    /// The model over the shared trail, with the running app's goals and conversations.
    static func live(conversations: ConversationStore) -> ActivityScreenModel {
        ActivityScreenModel(
            store: .shared,
            threadExists: { [weak conversations] id in
                conversations?.threads.contains { $0.id == id } ?? false
            })
    }
}
