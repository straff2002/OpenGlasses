import SwiftUI

/// Lists meeting summaries stored in the shared `saved_notes` key, filtering out
/// entries written by other note tools using the canonical meeting-title prefix.
struct MeetingRecordsView: View {
    @State private var records: [MeetingRecord] = []

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "No meeting records yet",
                    systemImage: "text.book.closed",
                    description: Text("Summaries appear here after the Meeting Summary tool runs. Say \"hey meeting\", or ask the assistant to summarize the meeting.")
                )
            } else {
                ForEach(records) { record in
                    NavigationLink {
                        MeetingRecordDetailView(record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title)
                                .font(.headline)

                            if let date = record.date {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Date unavailable")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(record.content)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete(perform: deleteRecords)
            }
        }
        .navigationTitle("Meeting Records")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .task {
            loadRecords()
        }
        .refreshable {
            loadRecords()
        }
    }

    private func loadRecords() {
        let notes = SavedNotesStore.load()
        let formatter = ISO8601DateFormatter()

        records = notes.compactMap { note in
            guard let title = note["title"],
                  title.hasPrefix(SiriContentAdapters.meetingSummaryTitlePrefix),
                  let content = note["content"] else {
                return nil
            }

            let dateString = note["date"]
            return MeetingRecord(
                id: recordID(title: title, dateString: dateString),
                title: title,
                content: content,
                date: dateString.flatMap { formatter.date(from: $0) },
                meetingId: note[MeetingActionItemsRecord.meetingIdKey]
            )
        }
        .sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?):
                return left > right
            case (.some, .none):
                return true
            case (.none, .some), (.none, .none):
                return false
            }
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        var notes = SavedNotesStore.load()

        for offset in offsets.sorted(by: >) {
            let record = records[offset]
            if let index = notes.firstIndex(where: { note in
                guard note["title"] == record.title else { return false }
                return recordID(title: record.title, dateString: note["date"]) == record.id
            }) {
                notes.remove(at: index)
            }
        }

        SavedNotesStore.save(notes)
        loadRecords()
    }

    private func recordID(title: String, dateString: String?) -> String {
        "\(title)\u{1F}\(dateString ?? "")"
    }
}

private struct MeetingRecord: Identifiable {
    let id: String
    let title: String
    let content: String
    let date: Date?
    /// A summary saved since its action items were kept with it (Plan MX P5).
    var meetingId: String? = nil
}

private struct MeetingRecordDetailView: View {
    let record: MeetingRecord

    @State private var items: MeetingActionItemsRecord?
    @State private var adding: Int?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let items, !items.isEmpty, let meetingId = record.meetingId {
                    actionItems(items, meetingId: meetingId)
                }
                Text(record.content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .task { reloadItems() }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: record.content) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share meeting record")
            }
        }
    }

    /// Each action item, with one way to put it in Reminders — once. "Added" is read back from the
    /// saved note, so it holds after a relaunch.
    private func actionItems(_ items: MeetingActionItemsRecord, meetingId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            OGSection(header: "Action items") {
                ForEach(Array(items.entries.enumerated()), id: \.offset) { index, entry in
                    if index > 0 { OGDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.item.readable)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.addedToReminders {
                            OGStatusLabel("Added", kind: .ok)
                                .accessibilityLabel(Text("Added to Reminders"))
                        } else if adding == index {
                            ProgressView()
                        } else {
                            Button("Add to Reminders") { add(index, meetingId: meetingId) }
                                .buttonStyle(.ogProminentCompact)
                                .disabled(adding != nil)
                        }
                    }
                    .padding(.horizontal, OGMetrics.rowHorizontalPadding)
                    .padding(.vertical, 12)
                }
            }
            if let problem {
                OGStatusLabel(problem, kind: .warn)
                    .padding(.horizontal, 20)
            }
        }
        .padding(.horizontal)
    }

    private func reloadItems() {
        guard let meetingId = record.meetingId else { return }
        items = MeetingActionReminders.record(meetingId: meetingId)
    }

    private func add(_ index: Int, meetingId: String) {
        guard adding == nil else { return }
        adding = index
        problem = nil
        Task { @MainActor in
            defer { adding = nil }
            let outcome = await MeetingActionReminders.add(index: index, meetingId: meetingId,
                                                           meetingTitle: record.title, saver: EventKitDayStore())
            switch outcome {
            case .added(let updated):
                items = updated
            case .alreadyAdded:
                reloadItems()
            case .noAccess:
                problem = String(localized: "Reminders access is off. Turn it on in Settings › Privacy & Security › Reminders.")
            case .failed:
                problem = String(localized: "That reminder couldn't be added. Try again.")
                reloadItems()
            }
        }
    }
}
