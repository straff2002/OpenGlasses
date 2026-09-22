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

            // The evidence exactly as it went out (Plan FO P2a) — the stored selection, not a
            // fresh proposal, so what is ticked here is what the customer's PDF was made from and
            // "Share full-size photos" hands out those same files.
            if let evidence = model.pastEvidence(sessionId: sessionId) {
                JobPhotosSection(review: evidence.review, selection: evidence.selection,
                                 onShare: { appState.presentEvidenceShare(
                                     evidence.review.shareURLs(for: evidence.selection)) })
            }

            // How the clips travel on the channel this report would go by (Plan FO P2b). Before
            // Send, not after: "that one is too large" is only useful while the share sheet is
            // still a tap away.
            if let clips = model.clipDelivery(sessionId: sessionId) {
                clipDeliverySection(clips)
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

    /// One row per clip: what it is, how long it runs, what it weighs, and whether it rides along
    /// or has to be shared. A clip that cannot be attached is never silently dropped — it gets a
    /// button of its own.
    @ViewBuilder
    private func clipDeliverySection(_ delivery: JobTabModel.ClipDelivery) -> some View {
        Section {
            Text(delivery.summary)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(delivery.clips) { clip in
                VStack(alignment: .leading, spacing: 4) {
                    Text(delivery.line(for: clip))
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = delivery.plan.reason(for: clip.id) {
                        Text("Not attached — \(reason).")
                            .font(.caption)
                            .foregroundStyle(OGTheme.warnLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Goes with the report.")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)

                if delivery.plan.reason(for: clip.id) != nil {
                    choice("Share this clip") {
                        appState.presentClipShare(model.clipURL(sessionId: sessionId,
                                                                itemId: clip.id))
                    }
                    .accessibilityHint("Opens the share sheet with this clip. Nothing is sent until you choose where.")
                }
            }
        } header: {
            Text("Clips with this report")
        } footer: {
            Text("A work order cannot contain a video, so a clip travels as a file of its own. The report names every clip either way, so the record is complete even when a clip goes separately.")
        }
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
            // One call builds the files *and* the clip partition, so the PDF's lines, the body's
            // note and the attachments cannot disagree about which clips travelled.
            let delivery = FieldSessionService.shared.reportDelivery(
                for: channel,
                canSendAttachments: channel == .messages
                    ? ReportComposerAvailability.messagesCanAttach : true,
                sessionId: job.sessionId)
            let request = DeliveryRequest.make(record: job.record, channel: channel,
                                               recipients: recipients,
                                               attachments: delivery.attachments,
                                               clipPlan: delivery.clipPlan,
                                               clipItems: delivery.clipItems)
            appState.presentDelivery(request)
        }
    }

}
