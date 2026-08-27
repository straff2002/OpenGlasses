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
                date: dateString.flatMap { formatter.date(from: $0) }
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
}

private struct MeetingRecordDetailView: View {
    let record: MeetingRecord

    var body: some View {
        ScrollView {
            Text(record.content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
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
}
