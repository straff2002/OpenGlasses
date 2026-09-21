import SwiftUI

/// One finished job (Plan FO P2): the work record as the export prints it, the conversation it
/// happened in, and a way to send the report again.
///
/// This is also where the app lands the moment a job is closed, so "close, check, send" is one
/// movement rather than a screen the technician has to go and find.
struct PastJobView: View {
    let sessionId: String
    let model: JobTabModel
    let onOpenTranscript: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var problem: String?
    @State private var readBack: [String]?

    private var job: JobTabModel.PastJob? { model.pastJob(id: sessionId) }

    var body: some View {
        Group {
            if let job {
                content(job)
            } else {
                ContentUnavailableView {
                    Label("That job isn't here", systemImage: "questionmark.folder")
                } description: {
                    Text("Its record could not be read back off the device.")
                }
            }
        }
        .navigationTitle(job?.jobNumber ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { readBack != nil }, set: { if !$0 { readBack = nil } })) {
            ReadBackSheet(lines: readBack ?? []) { readBack = nil }
        }
        .alert("Can't send that report", isPresented: Binding(get: { problem != nil },
                                                              set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder
    private func content(_ job: JobTabModel.PastJob) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.jobNumber)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(job.hasJobNumber ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(job.dateLine) · \(job.outcomeLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(job.vaultName) · \(job.billingLine)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)

                if !job.visitedUnits.isEmpty {
                    ForEach(job.visitedUnits, id: \.self) { unit in
                        Text(unit).font(.subheadline)
                    }
                }
            } header: {
                Text("The visit")
            }

            Section {
                ForEach(Array(job.summaryLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Work record")
            } footer: {
                Text("Assembled from what was recorded on the job — the same lines the work order prints.")
            }

            Section {
                if let threadId = job.threadId {
                    choice("Open the conversation") { onOpenTranscript(threadId) }
                        .accessibilityHint("Shows what was said on this job, read-only.")
                } else {
                    Text("No conversation was saved against this job.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                choice("Read back the job") { readBack = job.summaryLines }

                choice("Send report…") { sendReport(job) }
                    .accessibilityHint("Fills in the report and opens it. Nothing leaves the phone until you tap Send.")
            } header: {
                Text("This job")
            }
        }
        .ogFormStyle()
    }

    /// One tappable line in a section — leading-aligned and tinted, the way a `Form` button reads.
    private func choice(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }

    /// Re-send: the same policy, the same request shape and the same composer the job's own
    /// "send the report" uses — with this session's files rather than the active one's.
    private func sendReport(_ job: JobTabModel.PastJob) {
        let policy = DeliveryPolicy(settings: Config.deliverySettings)
        guard let channel = policy.defaultChannel else {
            problem = "No channel is allowed for job reports. Set one up under Settings → Field Assist → Job Reports."
            return
        }
        switch policy.decide(channel: channel) {
        case .refused(let reason):
            problem = reason
        case .allowed(let recipients):
            let request = DeliveryRequest.make(record: job.record, channel: channel,
                                               recipients: recipients,
                                               attachments: attachments(for: job))
            appState.presentDelivery(request)
        }
    }

    /// The finished session's own exported files. An export that refuses leaves the summary to
    /// travel on its own, which is what the composer already says it is doing.
    private func attachments(for job: JobTabModel.PastJob) -> [DeliveryRequest.Attachment] {
        guard let leases = try? FieldSessionService.shared.exportSession(id: job.sessionId,
                                                                        formats: [.json, .pdf]) else {
            return []
        }
        return leases.compactMap { lease in
            switch lease.fileURL.pathExtension.lowercased() {
            case "pdf":
                return DeliveryRequest.Attachment(url: lease.fileURL, kind: .pdf,
                                                  filename: job.record.reportFileStem + ".pdf")
            case "json":
                return DeliveryRequest.Attachment(url: lease.fileURL, kind: .json,
                                                  filename: job.record.reportFileStem + ".json")
            default:
                return nil
            }
        }
    }
}
