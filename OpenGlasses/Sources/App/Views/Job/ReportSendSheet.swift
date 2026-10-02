import SwiftUI

/// What a "Send report…" tap is about to send, before the composer opens (Plan HD).
struct ReportSendPlan: Identifiable, Equatable {
    let id = UUID()
    let channel: DeliveryChannel
    let recipients: [String]
    /// Whether this channel, on this device, carries a file at all.
    let carriesFiles: Bool
    let context: ReportTranscriptPolicy.Context

    /// The plan for a channel and its recipients, with the device's answer about attachments and
    /// the configuration as it stands.
    @MainActor
    static func make(channel: DeliveryChannel, recipients: [String]) -> ReportSendPlan {
        let canAttach = channel == .messages ? ReportComposerAvailability.messagesCanAttach : true
        return ReportSendPlan(
            channel: channel, recipients: recipients,
            carriesFiles: AttachmentBudget.standard(for: channel,
                                                    canSendAttachments: canAttach).carriesFiles,
            context: .current())
    }

    var canSendAttachments: Bool {
        channel == .messages ? carriesFiles : true
    }
}

/// The short sheet between "Send report…" and the composer (Plan HD): where the report goes, who
/// that is, and whether the conversation goes with it.
///
/// Thin on purpose. Every word and every state comes off `ReportTranscriptPolicy`; this view only
/// holds the two choices the technician can make and hands them back.
struct ReportSendSheet: View {
    let plan: ReportSendPlan
    let onContinue: (ReportTranscriptPolicy.Choice) -> Void
    let onCancel: () -> Void

    @State private var choice = ReportTranscriptPolicy.Choice.standard

    private var decision: ReportTranscriptPolicy.Decision {
        ReportTranscriptPolicy.decide(channel: plan.channel, recipients: plan.recipients,
                                      carriesFiles: plan.carriesFiles, context: plan.context,
                                      choice: choice)
    }

    var body: some View {
        let decision = decision
        NavigationStack {
            Form {
                Section {
                    LabeledContent("By", value: plan.channel.label)
                    if !plan.recipients.isEmpty {
                        LabeledContent("To", value: plan.recipients.joined(separator: ", "))
                    }
                    Text(decision.audienceLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if decision.offersOfficeOptIn {
                        Toggle("This is going to my office", isOn: $choice.markedAsOffice)
                    }
                } header: {
                    Text("Sending")
                } footer: {
                    if let footer = decision.officeOptInFooter { Text(footer) }
                }

                Section {
                    if decision.transcriptPDF.isShown {
                        Toggle("Include transcript (internal)", isOn: Binding(
                            get: { decision.transcriptPDF.isOn },
                            set: { choice.attachTranscript = $0 }))
                            .disabled(!decision.transcriptPDF.isEditable)
                    } else {
                        Text(decision.transcriptPDF.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Transcript")
                } footer: {
                    if decision.transcriptPDF.isShown {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(decision.transcriptPDF.note)
                            if let line = decision.dataFileLine { Text(line) }
                        }
                    }
                }
            }
            .ogFormStyle()
            .navigationTitle("Send report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { onContinue(choice) }
                        .accessibilityHint("Opens the report in \(plan.channel.label). Nothing leaves the phone until you tap Send.")
                }
            }
            // Taking back "going to my office" takes the transcript with it, so turning it on
            // again never revives a PDF the technician had stopped thinking about.
            .onChange(of: choice.markedAsOffice) { _, marked in
                if !marked { choice.attachTranscript = false }
            }
        }
    }
}
