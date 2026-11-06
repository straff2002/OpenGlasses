import SwiftUI

/// The expert's coaching steps for one handover (Plan KM §5, P3): numbered, typed or dictated with
/// the keyboard's own microphone, reordered, edited and deleted, and sent back as a coaching reply.
///
/// Every change is kept on the held handover at once, so a relaunch loses no step. Nothing leaves
/// until the expert taps Send and then the share sheet's own Send.
struct AssistingCoachingSection: View {
    @ObservedObject var service: AssistingService
    @ObservedObject var store: AssistingHandoverStore
    let handoverId: String
    /// Where a refusal is shown: the handover view's own problem line.
    @Binding var problem: String?

    @State private var editing: EditingStep?
    @State private var sharing: ShareItem?

    struct EditingStep: Identifiable {
        let id: String
        let step: CoachingStep?
    }

    private var steps: [CoachingStep] { store.handover(id: handoverId)?.coachingDraft ?? [] }

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                Button {
                    editing = EditingStep(id: step.id, step: step)
                } label: {
                    StepRow(number: index + 1, step: step)
                }
                .accessibilityHint("Edits this step.")
            }
            .onMove { service.moveCoachingSteps(for: handoverId, from: $0, to: $1) }
            .onDelete { service.deleteCoachingSteps(for: handoverId, at: $0) }

            if steps.count < CoachingStep.maxSteps {
                Button {
                    editing = EditingStep(id: UUID().uuidString, step: nil)
                } label: {
                    Label("Add a Step", systemImage: "plus")
                }
            }

            if !steps.isEmpty {
                if case .success(let reply)? = service.coachingReply(for: handoverId) {
                    Text(reply.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(store.handover(id: handoverId)?.coachingSentAt == nil
                       ? "Send Coaching Steps…" : "Send Coaching Steps Again…") {
                    send()
                }
                .accessibilityHint("Prepares a small file and opens the share sheet. Nothing is sent until you send it there.")
                if let sent = store.handover(id: handoverId)?.coachingSentAt {
                    Text("Coaching shared \(sent.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text("Coaching steps")
                Spacer()
                if steps.count > 1 { EditButton().font(.caption) }
            }
        } footer: {
            Text("Write the steps for the technician to walk, one at a time. Each can ask for a reading and say when to stop. Their assistant reads each step as you wrote it, with any safety rule it touches read first. Tap the microphone on the keyboard to dictate.")
        }
        .sheet(item: $editing) { item in
            NavigationStack {
                CoachingStepEditor(stepId: item.id, existing: item.step) { step in
                    service.saveCoachingStep(step, for: handoverId)
                }
            }
        }
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
    }

    private func send() {
        switch service.stageCoaching(for: handoverId) {
        case .failure(let refusal):
            problem = refusal.message
        case .success(let staged):
            problem = nil
            service.beginShare(staged)
            let id = handoverId
            let item = ProtectedExportActivityItem(fileURL: staged.lease.fileURL, displayName: staged.lease.displayName)
            sharing = ShareItem(items: [item]) { completed in
                service.finishShare(staged, for: id, completed: completed)
            }
        }
    }

    private struct StepRow: View {
        let number: Int
        let step: CoachingStep

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(step.instruction)")
                    .foregroundStyle(.primary)
                if let reading = step.reading {
                    Text("Reading: \(reading.phrase)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let stopIf = step.stopIf {
                    Text("Stop if: \(stopIf)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }
}

/// One coaching step: the instruction, an optional reading with its unit, and an optional "stop if".
struct CoachingStepEditor: View {
    let stepId: String
    let onSave: (CoachingStep) -> String?

    @State private var instruction: String
    @State private var quantity: String
    @State private var unit: String
    @State private var stopIf: String
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(stepId: String, existing: CoachingStep?, onSave: @escaping (CoachingStep) -> String?) {
        self.stepId = stepId
        self.onSave = onSave
        _instruction = State(initialValue: existing?.instruction ?? "")
        _quantity = State(initialValue: existing?.reading?.quantity ?? "")
        _unit = State(initialValue: existing?.reading?.unit ?? "")
        _stopIf = State(initialValue: existing?.stopIf ?? "")
    }

    private var step: CoachingStep {
        CoachingStep(id: stepId, instruction: instruction, readingQuantity: quantity, readingUnit: unit, stopIf: stopIf)
    }

    var body: some View {
        Form {
            Section {
                TextField("What to do", text: $instruction, axis: .vertical)
                    .lineLimit(3...8)
            } header: {
                Text("Instruction")
            } footer: {
                Text("Read to the technician exactly as you write it.")
            }

            Section {
                TextField("What to read", text: $quantity)
                TextField("Unit", text: $unit)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Reading to take")
            } footer: {
                Text("Optional. What they report is kept against this step on the job's record.")
            }

            Section {
                TextField("Stop if…", text: $stopIf, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Stop if")
            } footer: {
                Text("Optional. If it applies, the walkthrough stops here and the technician is told to call you back.")
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Coaching step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if let why = onSave(step) {
                        problem = why
                    } else {
                        dismiss()
                    }
                }
                .disabled(step.instruction.isEmpty)
            }
        }
    }
}
