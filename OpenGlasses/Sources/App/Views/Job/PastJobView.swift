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
    @State private var transcriptProblem: String?
    @State private var readBack: [String]?
    /// The customer sign-off, when it is being taken after the close (Plan FO P2c).
    @State private var signOffStep: SignOffStep?
    /// Whether this job can still be signed. Read once when the page appears and again after an
    /// answer, rather than on every pass of the body: the answer comes off the session's own log
    /// on disk, and a `List` re-evaluates its body far more often than a report is sent.
    @State private var canStillSign = false
    /// The debrief sheet, while one is being taken on the phone (Plan FO P3b).
    @State private var showingDebrief = false

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
        .alert("Can't export the transcript",
               isPresented: Binding(get: { transcriptProblem != nil },
                                    set: { if !$0 { transcriptProblem = nil } })) {
            Button("OK") { transcriptProblem = nil }
        } message: {
            Text(transcriptProblem ?? "")
        }
        .onAppear { canStillSign = model.signOffIsStillOpen(sessionId: sessionId) }
        .sheet(isPresented: $showingDebrief) {
            if let active = appState.guidedJobFlow.debrief {
                JobDebriefSheet(
                    debrief: active,
                    onFinish: { Task { await appState.guidedJobFlow.finishDebrief() } },
                    onSave: { Task { await appState.guidedJobFlow.saveDebrief() } },
                    onDiscard: { Task { await appState.guidedJobFlow.discardDebrief() } },
                    onRetry: { Task { await appState.guidedJobFlow.retryDebriefSummary() } },
                    onKeepRaw: { Task { await appState.guidedJobFlow.keepDebriefRaw() } },
                    onClose: {
                        appState.guidedJobFlow.endDebrief()
                        showingDebrief = false
                    })
            }
        }
        .sheet(item: $signOffStep) { step in
            JobSignOffStepView(
                summaryLines: step.lines,
                jobNumber: step.jobNumber,
                dateLine: step.dateLine,
                organisationName: Config.organizationDisplayName,
                required: model.signOffRequired,
                onSignOff: { signOff, png, strokes in
                    record(signOff, pngData: png, strokeData: strokes)
                },
                onDeclined: { reason in
                    record(CustomerSignOff(customerName: "", method: .declined,
                                           declinedReason: reason, summaryLines: step.lines))
                },
                onSkip: { signOffStep = nil },
                onCancelledHandOver: { model.signOffCancelled(sessionId: sessionId) },
                onCancel: { signOffStep = nil })
        }
    }

    /// Open the step with the summary as this finished job's record renders it now.
    private func beginSignOff() {
        guard let lines = model.customerSummaryLines(sessionId: sessionId),
              let heading = model.signOffHeading(sessionId: sessionId) else { return }
        signOffStep = SignOffStep(lines: lines, jobNumber: heading.jobNumber,
                                  dateLine: heading.dateLine, evidence: nil)
    }

    private func record(_ signOff: CustomerSignOff, pngData: Data? = nil, strokeData: Data? = nil) {
        model.recordSignOff(sessionId: sessionId, signOff, pngData: pngData, strokeData: strokeData)
        signOffStep = nil
        canStillSign = model.signOffIsStillOpen(sessionId: sessionId)
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

            // What the customer agreed to, or the offer to ask them (Plan FO P2c). It sits after
            // the evidence and before the actions because that is the order the job ended in: the
            // pictures were chosen, the customer signed, and only then does anything get sent.
            signOffSection

            // What was said about the job afterwards (Plan FO P3b). After the acceptance, because
            // that is the order it happened in, and read-only: a debrief is added by talking, and
            // saving one is the only thing that writes.
            let debriefs = model.debriefs(sessionId: sessionId)
            if !debriefs.isEmpty { JobDebriefSection(debriefs: debriefs) }

            Section {
                if let threadId = job.threadId {
                    choice("Open the conversation") { onOpenTranscript(threadId) }
                        .accessibilityHint("Shows what was said on this job, read-only.")
                } else {
                    Text("No conversation was saved against this job.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                choice("Export transcript…") { exportTranscript() }
                    .accessibilityHint("Makes a text file of everything said on this job. Nothing leaves the phone until you choose where it goes.")

                choice("Read back the job") { readBack = job.summaryLines }

                choice("Debrief this job") { beginDebrief() }
                    .accessibilityHint("Talk the job over. Nothing is added until you save it.")

                choice("Send report…") { sendReport(job) }
                    .accessibilityHint("Fills in the report and opens it. Nothing leaves the phone until you tap Send.")

                // Only when there is something a second document would carry: before the report
                // has gone, a debrief prints in the work order itself.
                if model.hasAddendum(sessionId: sessionId) {
                    choice("Send addendum…") { sendAddendum(job) }
                        .accessibilityHint("Sends the debrief as a second document. The work order already sent is unchanged.")
                }
            } header: {
                Text("This job")
            }
        }
        .ogFormStyle()
    }

    /// The acceptance, when there is one; the offer to take it, while the report has not gone; and
    /// a plain statement of the fact when it is too late for either.
    @ViewBuilder
    private var signOffSection: some View {
        if let signOff = model.signOff(sessionId: sessionId) {
            CustomerAcceptanceSection(
                signOff: signOff,
                signatureURL: signOff.signatureImageId.map {
                    model.signatureURL(sessionId: sessionId, imageId: $0)
                })
        } else if canStillSign {
            Section {
                choice("Customer sign-off") { beginSignOff() }
                    .accessibilityHint("Shows the customer what was done and takes their signature. Nothing is sent by signing.")
            } header: {
                Text(CustomerSignOff.blockTitle)
            } footer: {
                Text("This job wasn't signed. You can still ask until the report has been sent.")
            }
        } else {
            Section {
                Text("The customer did not sign this job, and the report has already been sent.")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(CustomerSignOff.blockTitle)
            }
        }
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

    /// The job's conversation as a text file, in the share sheet — for support, or for the office
    /// when a customer says something went wrong on the visit.
    private func exportTranscript() {
        Task {
            if let trouble = await appState.presentTranscriptExport(.job(sessionId: sessionId)) {
                transcriptProblem = trouble
            }
        }
    }

    /// Start a debrief on this job, through the flow — the same chokepoint the car goes through,
    /// so the phone and CarPlay cannot end up doing different things.
    private func beginDebrief() {
        Task {
            let started = await appState.guidedJobFlow.startDebrief(jobId: sessionId)
            if started { showingDebrief = true }
            else { problem = "That job's record could not be read back off the device." }
        }
    }

    /// The addendum: the same channel the original went by, the same composer, a second document.
    /// Never automatic — this is a tap, and the composer is another.
    private func sendAddendum(_ job: JobTabModel.PastJob) {
        let sessions = FieldSessionService.shared
        let policy = DeliveryPolicy(settings: Config.deliverySettings)
        let channel = sessions.lastDeliveryChannel(sessionId: job.sessionId)
            ?? policy.defaultChannel
        guard let channel else {
            problem = "No channel is allowed for job reports. Set one up under Settings → Field Assist → Job Reports."
            return
        }
        switch policy.decide(channel: channel) {
        case .refused(let reason):
            problem = reason
        case .allowed(let recipients):
            guard let attachment = sessions.addendumAttachment(sessionId: job.sessionId) else {
                problem = "There's nothing to add to that report yet."
                return
            }
            appState.presentDelivery(DeliveryRequest.make(
                record: job.record, channel: channel, recipients: recipients,
                attachments: [attachment]))
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
