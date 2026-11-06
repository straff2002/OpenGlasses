import SwiftUI
import UIKit

/// One handover, read-only (Plan KM §7, P2): the job as the technician's phone sent it, what
/// changed in the latest update, the photos, and the expert's own controls — Take this job,
/// Pause, Resume, Done — the coaching steps they write for it (P3) and, once Done, the time reply.
///
/// **Nothing here can touch the technician's job.** Every row is text from the file; there is no
/// edit, no tool and no link into Field Assist. A manual is named, never opened from here. The
/// only thing that leaves is the reply, from the share sheet the expert opens.
struct AssistingHandoverView: View {
    @ObservedObject var service: AssistingService
    @ObservedObject private var store: AssistingHandoverStore
    let handoverId: String
    /// What opening the file said, shown once at the top when the view is the one opening raised.
    var openingMessage: String?

    @State private var note = ""
    @State private var problem: String?
    @State private var sharing: ShareItem?
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    init(service: AssistingService, handoverId: String, openingMessage: String? = nil) {
        self.service = service
        _store = ObservedObject(wrappedValue: service.store)
        self.handoverId = handoverId
        self.openingMessage = openingMessage
    }

    var body: some View {
        Group {
            if let held = store.handover(id: handoverId) {
                form(held)
            } else {
                Text("This handover is no longer on this phone.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
        // The note is kept as far as it is written (Plan KM P3), so leaving the view loses none.
        .onAppear { note = service.noteDraft(for: handoverId) }
        .onDisappear { service.saveNote(note, for: handoverId) }
    }

    private var title: String {
        store.handover(id: handoverId)?.handover.job.reference.map { String(localized: "Job \($0)") }
            ?? String(localized: "Job handover")
    }

    @ViewBuilder
    private func form(_ held: HeldHandover) -> some View {
        let handover = held.handover
        Form {
            Section {
                if let openingMessage {
                    Text(openingMessage)
                        .font(.callout)
                }
                LabeledContent("From", value: handover.organisation.name.isEmpty ? String(localized: "Not named") : handover.organisation.name)
                LabeledContent("Update", value: "\(handover.generation)")
                LabeledContent("Sent to", value: handover.expert.name)
                if !held.changes.isEmpty {
                    ForEach(held.changes.lines, id: \.self) { line in
                        Label(line, systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout)
                    }
                }
            } footer: {
                Text("\(handover.organisation.confidentiality). Kept on this phone only, and deleted \(handover.retentionDays) days after you tap Done.")
            }

            clockSection(held)

            // Plan KM P3: the steps the expert writes for the technician to walk.
            AssistingCoachingSection(service: service, store: store, handoverId: handoverId, problem: $problem)

            if held.clock?.isDone == true {
                replySection(held)
            }

            if let question = handover.question {
                Section(header: header("The question", .question, held)) {
                    Text(question)
                }
            }

            jobSection(held)
            workSection(held)

            if handover.conversation.included, !handover.conversation.lines.isEmpty {
                Section(header: header("The conversation", .conversation, held)) {
                    ForEach(Array(handover.conversation.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.speaker)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(line.text)
                        }
                    }
                }
            }

            photoSection(held)

            if !handover.manualReferences.isEmpty {
                Section {
                    ForEach(Array(handover.manualReferences.enumerated()), id: \.offset) { _, reference in
                        Text(Self.reference(reference))
                    }
                } header: {
                    header("Manuals used", .manuals, held)
                } footer: {
                    Text("Named only. The pages aren't in the handover; use your own copy if you have one.")
                }
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete This Handover", role: .destructive) { confirmingDelete = true }
                    .confirmationDialog("Delete this handover?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            service.delete(handoverId)
                            dismiss()
                        }
                    } message: {
                        Text("Its photos and your clock go with it. A reply you haven't sent can't be sent after.")
                    }
            }
        }
        .ogFormStyle()
    }

    // MARK: - The clock

    @ViewBuilder
    private func clockSection(_ held: HeldHandover) -> some View {
        Section {
            if let clock = held.clock {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LabeledContent("Your time", value: Self.minutes(clock.minutes(at: context.date)))
                }
                if clock.pausedWhenAppClosed, clock.uncountedMinutes > 0 {
                    Text("Paused when the app closed. \(Self.minutes(clock.uncountedMinutes)) not counted, and your reply says so.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if clock.isRunning {
                    Button("Pause") { service.pause(handoverId) }
                    Button("Done") { service.done(handoverId) }
                } else if clock.isPaused {
                    Button("Resume") { service.resume(handoverId) }
                    Button("Done") { service.done(handoverId) }
                } else {
                    Text("Done.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    service.take(handoverId)
                } label: {
                    Text("Take This Job")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts your clock. Pause it when you stop, and tap Done when you've finished.")
            }
        } header: {
            Text("Your time")
        } footer: {
            Text("The clock runs while you work on this job, including a call. Your time goes back to the organisation in your reply; your rate is between you and them.")
        }
    }

    @ViewBuilder
    private func replySection(_ held: HeldHandover) -> some View {
        Section {
            TextField("A short note for the technician", text: $note, axis: .vertical)
                .lineLimit(2...5)
            if case .success(let reply)? = service.reply(for: handoverId, note: note) {
                Text(reply.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(held.replySentAt == nil ? "Send Time Reply…" : "Send Time Reply Again…") {
                sendReply()
            }
            .accessibilityHint("Prepares a small file and opens the share sheet. Nothing is sent until you send it there.")
            if let sent = held.replySentAt {
                Text("Reply shared \(sent.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Your reply")
        } footer: {
            Text("Send it to the technician the way the job came to you. It carries your time, every update you saw and your note.")
        }
    }

    private func sendReply() {
        service.saveNote(note, for: handoverId)
        switch service.stageReply(for: handoverId, note: note) {
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

    // MARK: - The job

    @ViewBuilder
    private func jobSection(_ held: HeldHandover) -> some View {
        let job = held.handover.job
        Section(header: header("The job", .job, held)) {
            if let reference = job.reference { LabeledContent("Reference", value: reference) }
            if !job.trades.isEmpty { LabeledContent("Trade", value: job.trades.joined(separator: ", ")) }
            if let town = job.site?.town { LabeledContent("Town", value: town) }
            if let address = job.site?.address { LabeledContent("Address", value: address) }
            if let fault = job.faultReport {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fault reported, \(fault.source)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fault.text)
                }
            }
        }
        if let unit = job.unit {
            Section(header: header("The unit", .unit, held)) {
                if let model = unit.model { LabeledContent("Model", value: model) }
                if let section = unit.matchedSection { LabeledContent("Matched", value: section) }
                ForEach(Array(unit.identity.enumerated()), id: \.offset) { _, field in
                    LabeledContent(field.name) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(field.value)
                            Text(field.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workSection(_ held: HeldHandover) -> some View {
        let work = held.handover.work
        if !work.tasks.isEmpty {
            Section(header: header("Tasks", .tasks, held)) {
                ForEach(Array(work.tasks.enumerated()), id: \.offset) { _, task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                        Text(([Self.status(task.status)] + [task.note].compactMap { $0 }).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !work.procedures.isEmpty {
            Section(header: header("Procedures", .procedures, held)) {
                ForEach(Array(work.procedures.enumerated()), id: \.offset) { _, line in
                    LabeledContent(line.procedure, value: line.outcome ?? String(localized: "\(line.stepsDone) steps done"))
                }
            }
        }
        if !work.readings.isEmpty {
            Section(header: header("Readings", .readings, held)) {
                ForEach(Array(work.readings.enumerated()), id: \.offset) { _, reading in
                    LabeledContent(reading.quantity) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text([reading.value, reading.unit].compactMap { $0 }.joined(separator: " "))
                            Text(reading.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if !work.ruledOut.isEmpty {
            Section {
                ForEach(work.ruledOut, id: \.self) { Text($0) }
            } header: {
                header("Ruled out", .ruledOut, held)
            } footer: {
                Text("In the technician's words.")
            }
        }
        if !work.deviations.isEmpty {
            Section(header: header("Done differently", .deviations, held)) {
                ForEach(work.deviations, id: \.self) { Text($0) }
            }
        }
    }

    @ViewBuilder
    private func photoSection(_ held: HeldHandover) -> some View {
        let photos = held.handover.photos
        let left = held.handover.photosLeftOut
        if !photos.isEmpty || left.total > 0 {
            Section {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                    VStack(alignment: .leading, spacing: 4) {
                        if let data = store.photo(handoverId: handoverId, index: index), let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel(Text(photo.caption ?? String(localized: "Photo \(index + 1)")))
                        }
                        Text(photo.caption ?? String(localized: "Photo \(index + 1)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                header("Photos", .photos, held)
            } footer: {
                if left.total > 0 {
                    Text("\(left.total) more stayed on the technician's phone.")
                } else {
                    Text("Faces were blurred before the photos were sent.")
                }
            }
        }
    }

    // MARK: - Words

    private func header(_ title: LocalizedStringKey, _ section: HandoverChanges.Section, _ held: HeldHandover) -> some View {
        HStack {
            Text(title)
            if held.changes.contains(section) {
                Text("Changed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    static func minutes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 minute") : String(localized: "\(count) minutes")
    }

    static func reference(_ reference: ExpertHandover.ManualReference) -> String {
        var parts = [reference.title]
        if let page = reference.page { parts.append(String(localized: "page \(page)")) }
        if let section = reference.section { parts.append(section) }
        return parts.joined(separator: ", ")
    }

    static func status(_ raw: String) -> String {
        switch raw {
        case "recommended": return String(localized: "Recommended")
        case "accepted": return String(localized: "Accepted")
        case "declined": return String(localized: "Declined")
        case "deferred": return String(localized: "Deferred")
        case "in_progress": return String(localized: "In progress")
        case "done": return String(localized: "Done")
        case "abandoned": return String(localized: "Abandoned")
        default: return raw
        }
    }
}

/// Puts a handover the app just opened on screen, wherever the app is.
struct AssistingSheetHost: ViewModifier {
    @ObservedObject var service: AssistingService

    func body(content: Content) -> some View {
        content.sheet(item: $service.presented) { presented in
            NavigationStack {
                AssistingHandoverView(service: service, handoverId: presented.id, openingMessage: presented.message)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { service.presented = nil }
                        }
                    }
            }
        }
    }
}
