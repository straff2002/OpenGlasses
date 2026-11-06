import SwiftUI

/// The handover sheet (Plan KM P1): who the job goes to, by what, and what goes — the photos the
/// technician ticks (the newest four to begin with), whether the conversation goes, their question
/// and what they have ruled out. Nothing leaves until Send here (or "send it"), and then the
/// composer's own Send.
///
/// Thin on purpose: the draft lives on `JobSendService`, every rule is in the pure types, and this
/// view only edits the draft and hands it back.
struct ExpertHandoverSheet: View {
    @ObservedObject var sends: JobSendService
    @State private var outcome: String?

    var body: some View {
        NavigationStack {
            if let draft = sends.handoverDraft {
                form(draft)
            } else {
                Text("Nothing is waiting to send.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ExpertHandoverDraft, T>, default value: T) -> Binding<T> {
        Binding(get: { sends.handoverDraft?[keyPath: keyPath] ?? value },
                set: { newValue in sends.handoverDraft?[keyPath: keyPath] = newValue })
    }

    @ViewBuilder
    private func form(_ draft: ExpertHandoverDraft) -> some View {
        let transcript = draft.transcript
        Form {
            Section {
                LabeledContent("To", value: draft.expert.contact.name)
                LabeledContent("By", value: channelLabel(draft.channel))
                LabeledContent("Update", value: "\(draft.generation)")
            } header: {
                Text(draft.jobNumber)
            } footer: {
                Text(draft.generation > 1
                     ? "This update replaces the one sent before. The unit, the work so far, the readings and the manual pages by name go with it. The customer's name and contact never do."
                     : "The unit, the work so far, the readings and the manual pages by name go with it. The customer's name and contact never do.")
            }

            Section {
                TextField("What do you want help with?", text: binding(\.question, default: ""), axis: .vertical)
                    .lineLimit(2...5)
                TextField("Ruled out so far, one per line", text: binding(\.ruledOut, default: ""), axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("In your words")
            } footer: {
                Text("Only what you write here is listed as ruled out.")
            }

            Section {
                Toggle("Include the conversation", isOn: Binding(
                    get: { transcript.includesTranscript },
                    set: { sends.handoverDraft?.transcriptChoice = $0 }))
                    .disabled(!transcript.toggle.isEditable)
            } header: {
                Text("Conversation")
            } footer: {
                Text(ReportTranscriptPolicy.expertNote(transcript,
                                                       onOrganisationList: draft.expert.source == .organization,
                                                       rule: draft.transcriptRule))
            }

            Section {
                if draft.photoCandidates.isEmpty {
                    Text("This job has no photos.")
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.photoCandidates) { item in
                    Toggle(isOn: Binding(
                        get: { sends.handoverDraft?.chosenPhotoIds.contains(item.id) ?? false },
                        set: { on in
                            if on { sends.handoverDraft?.chosenPhotoIds.insert(item.id) }
                            else { sends.handoverDraft?.chosenPhotoIds.remove(item.id) }
                        })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.caption ?? String(localized: "Photo"))
                            Text(item.capturedAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Photos")
            } footer: {
                Text("Faces are blurred in every photo. A photo that can't be blurred, or that doesn't fit, stays on this phone, oldest first, and the expert is told how many.")
            }

            if let outcome {
                Section {
                    Text(outcome)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Anyone you send this to can forward it. It is marked confidential to your organisation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .ogFormStyle()
        .navigationTitle("Send to an expert")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { sends.cancelHandover() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { outcome = sends.confirmHandover() }
                    .accessibilityHint("Prepares the files and opens them for you to send. Nothing leaves the phone until you tap Send there.")
            }
        }
    }

    private func channelLabel(_ channel: DeliveryChannel) -> String {
        channel == .shareSheet ? String(localized: "Share sheet") : channel.label
    }
}

/// Puts the handover sheet up wherever it was asked for: by voice on any tab, or from the job.
struct ExpertHandoverSheetHost: ViewModifier {
    @ObservedObject var sends: JobSendService

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { sends.handoverDraft != nil },
            set: { shown in if !shown { sends.cancelHandover() } })) {
            ExpertHandoverSheet(sends: sends)
        }
    }
}

/// "Send the job to an expert…" on the open job: choose who, then the sheet.
struct ExpertHandoverStartRow: View {
    let sends: JobSendService
    @State private var choosing = false
    @State private var refusal: String?

    private var service: ExpertHandoverService { .shared }

    var body: some View {
        if service.availability().isOffered {
            Button {
                choosing = true
            } label: {
                Text("Send the job to an expert…")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Choose who, then check what goes. Nothing is sent until you tap Send.")
            .confirmationDialog("Send the job to", isPresented: $choosing, titleVisibility: .visible) {
                ForEach(ExpertListStore.shared.entries) { entry in
                    Button(entry.contact.name) { start(entry.contact) }
                }
            }
            .alert("Can't send the job", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refusal ?? "")
            }
        }
    }

    private func start(_ contact: EscalationContact) {
        switch service.draft(for: contact) {
        case .failure(let failure): refusal = failure.message
        case .success(let draft): sends.proposeHandover(draft)
        }
    }
}
