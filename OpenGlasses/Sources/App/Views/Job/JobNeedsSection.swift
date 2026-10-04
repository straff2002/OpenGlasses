import QuickLook
import SwiftUI

/// What follows a job from the office: the attachments its job file named by digest, and the
/// manual sets it said it needs. Each says where it is — ready, still downloading, waiting for
/// Wi-Fi, waiting for the office — and a ready attachment opens when tapped.
///
/// Shows nothing for a job that named nothing.
struct JobNeedsSection: View {
    let needs: JobNeeds?
    @EnvironmentObject private var appState: AppState
    @State private var previewURL: URL?

    var body: some View {
        if let needs, !needs.isEmpty {
            Section {
                if let store = appState.officeJobAttachments {
                    JobAttachmentRows(attachments: needs.attachments, store: store, previewURL: $previewURL)
                } else {
                    ForEach(needs.attachments) { attachment in
                        JobNeedRow(status: .init(title: attachment.name,
                                                 detail: "Not on this phone.", systemImage: "doc"))
                    }
                }
                if let manuals = appState.officeManuals {
                    JobManualSetRows(sets: needs.manualSets, manuals: manuals)
                } else {
                    ForEach(needs.manualSets, id: \.self) { set in
                        JobNeedRow(status: OfficeJobAttachmentStore.status(set: set, standing: nil))
                    }
                }
            } header: {
                Text("From the office")
            } footer: {
                Text("Attachments and manuals this job names. Large files come over Wi-Fi at the office.")
            }
            .quickLookPreview($previewURL)
        }
    }
}

private struct JobAttachmentRows: View {
    let attachments: [JobNeeds.Attachment]
    @ObservedObject var store: OfficeJobAttachmentStore
    @Binding var previewURL: URL?

    var body: some View {
        ForEach(attachments) { attachment in
            let state = store.state(of: attachment)
            let status = OfficeJobAttachmentStore.status(attachment, state: state)
            if case .ready(let file) = state {
                Button { previewURL = file } label: { JobNeedRow(status: status) }
                    .accessibilityHint("Opens the attachment.")
            } else {
                JobNeedRow(status: status)
            }
        }
    }
}

private struct JobManualSetRows: View {
    let sets: [String]
    @ObservedObject var manuals: OfficeManualService

    var body: some View {
        ForEach(sets, id: \.self) { set in
            JobNeedRow(status: OfficeJobAttachmentStore.status(set: set, standing: manuals.standing(ofSet: set)))
        }
    }
}

private struct JobNeedRow: View {
    let status: OfficeFieldConnectionPolicy.Status

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: status.title)
                if let detail = status.detail {
                    Text(verbatim: detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: status.systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}
