import SwiftUI

/// What the office has said about a job since it was sent: a part's state, a new time, a note.
/// Newest first. Shown when the technician opens the job, and only read: nothing here changes
/// the job.
///
/// Shows nothing for a job the office has no identifier for, or one with no updates.
struct JobUpdatesSection: View {
    /// The office's identifier for the job, from its job file.
    let jobID: String?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let jobID, let updates = appState.officeJobUpdates {
            JobUpdateRows(jobID: jobID, updates: updates)
        }
    }
}

private struct JobUpdateRows: View {
    let jobID: String
    @ObservedObject var updates: OfficeJobUpdateService
    /// The updates that were new when the job was opened, so they stay marked while it is open.
    @State private var fresh: Set<String> = []

    var body: some View {
        let entries = updates.updates(forJob: jobID)
        if !entries.isEmpty {
            Section {
                ForEach(entries) { entry in
                    let status = OfficeJobUpdateService.status(entry.update)
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: status.title)
                                if fresh.contains(entry.id) || entry.openedAt == nil {
                                    Text("New")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let detail = status.detail {
                                Text(verbatim: detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Text(Date(timeIntervalSince1970: TimeInterval(entry.update.issuedAt))
                                .formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    } icon: {
                        Image(systemName: status.systemImage)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Updates from the office")
            } footer: {
                Text("What the office has said about this job since it was sent. The job itself is unchanged.")
            }
            .onAppear {
                fresh.formUnion(entries.filter { $0.openedAt == nil }.map(\.id))
                updates.markOpened(jobID: jobID)
            }
        }
    }
}
