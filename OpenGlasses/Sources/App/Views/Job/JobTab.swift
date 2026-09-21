import SwiftUI

/// Where a technician goes to see the job they are on (Plan FO P2).
///
/// The thing a service technician thinks in is *the job*, and until now the job was invisible
/// unless you asked the assistant about it out loud. This tab gives it a home: what is open, what
/// number it is filed under, how long it has been running, which machine it is on, what was
/// recommended and decided, and — when it is over — where to find it again.
///
/// **It is not a second chat surface.** The Voice tab stays the way work is captured and the
/// capsule stays primary; there is no wake-word row here (that lives in Field Assist settings,
/// beside the two settings that actually govern it). What this adds is buttons for the moments
/// voice fails: a plant room with a compressor running, a customer standing over the technician's
/// shoulder, a job number the recogniser has now misheard twice.
struct JobTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // The flow is what publishes the change-of-unit question, so the content view observes it
        // directly rather than through `AppState`, which does not republish its children.
        JobTabContent(flow: appState.guidedJobFlow)
    }
}

/// Where a page inside the tab goes. One enum so the stack is a value the views can push onto
/// without knowing about each other.
enum JobRoute: Hashable {
    case pastJob(sessionId: String)
    case transcript(threadId: String)
}

private struct JobTabContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var flow: GuidedJobFlow
    @StateObject private var sessions = FieldSessionService.shared

    @State private var path: [JobRoute] = []
    /// The number being typed, either to start a job with or to record on the open one.
    @State private var typedReference = ""
    @State private var search = ""
    /// The read-back, on screen as well as in the ear — a technician confirms what they can see.
    @State private var readBack: [String]?
    /// Raised by "Start a separate chat", never by a view body: the flow writes the question into
    /// the audit log as it produces it.
    @State private var leaveThread: JobTabModel.ThreadQuestionCard?
    @State private var confirmingClose = false
    @State private var problem: String?
    /// Re-read on a timer rather than every frame — see `JobClock`.
    @State private var clock = Date()

    private var model: JobTabModel { JobTabModel(host: sessions, flow: flow) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch model.state {
                case .noJob(let empty):
                    NoActiveJobView(empty: empty, model: model, search: $search,
                                    typedReference: $typedReference,
                                    onStart: startJob,
                                    onOpenPastJob: { path.append(.pastJob(sessionId: $0)) })
                case .running(let job), .paused(let job):
                    ActiveJobView(job: job, model: model,
                                  typedReference: $typedReference,
                                  leaveThread: $leaveThread,
                                  unitQuestion: model.unitQuestion,
                                  onAnswerUnit: { action in Task { await model.answer(action) } },
                                  onPauseResume: pauseOrResume,
                                  onOpenConversation: openConversation,
                                  onReadBack: readBackTheJob,
                                  onClose: { confirmingClose = true })
                }
            }
            .navigationTitle("Job")
            .navigationDestination(for: JobRoute.self) { route in
                switch route {
                case .pastJob(let id):
                    PastJobView(sessionId: id, model: model,
                                onOpenTranscript: { path.append(.transcript(threadId: $0)) })
                case .transcript(let id):
                    JobTranscriptView(threadId: id)
                }
            }
        }
        // The elapsed line is minute-grained, so it is re-read on the minute rather than on every
        // published change. A VoiceOver user focused on the row hears a value that settles.
        .onReceive(JobClock.tick) { clock = $0 }
        .sheet(isPresented: Binding(get: { readBack != nil }, set: { if !$0 { readBack = nil } })) {
            ReadBackSheet(lines: readBack ?? []) { readBack = nil }
        }
        .confirmationDialog("Close this job?", isPresented: $confirmingClose, titleVisibility: .visible) {
            // Plan FO P2a slots its evidence review in here: the photos and clips are chosen
            // before the job is closed, because closing is what makes the record final.
            Button("Close job", role: .destructive) { closeJob() }
            Button("Keep working", role: .cancel) {}
        } message: {
            Text("Time stops, the record is finished, and the job's conversation is closed with it. You can still send the report afterwards.")
        }
        .alert("That didn't work", isPresented: Binding(get: { problem != nil },
                                                        set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Actions

    private func startJob() {
        do {
            try model.startJob(jobReference: typedReference)
            typedReference = ""
        } catch {
            problem = error.localizedDescription
        }
    }

    private func pauseOrResume() {
        do { _ = try model.pauseOrResume() } catch { problem = error.localizedDescription }
    }

    private func closeJob() {
        do {
            let closed = try model.closeJob()
            typedReference = ""
            // Straight to the finished job: its record, its conversation, and Send report. The
            // close, the export and the delivery are the shipped ones — nothing here re-implements
            // any of them.
            path.append(.pastJob(sessionId: closed.session.id))
        } catch {
            problem = error.localizedDescription
        }
    }

    private func openConversation() {
        switch model.openConversation() {
        case .none:
            problem = "Nothing has been said on this job yet, so it has no conversation to open."
        case .asks(let question):
            leaveThread = question
        case .open(let threadId):
            // Through the flow above, which has already resumed the thread — id *and* history.
            // All that is left is to put the technician in front of it.
            appState.openChatThread(threadId)
        }
    }

    private func readBackTheJob() {
        readBack = model.readBackLines
        if let speech = model.readBackSpeech {
            Task { await appState.speechService.speak(speech) }
        }
    }
}

/// One shared minute tick for the Job tab's elapsed line.
///
/// A published change per second would redraw the screen sixty times a minute for a value that
/// only changes once, and would keep re-announcing itself under a VoiceOver cursor. Minute
/// granularity matches what the record prints.
enum JobClock {
    static let tick = Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()
}

/// The record on screen as well as in the ear, so a technician confirms what they can see.
struct ReadBackSheet: View {
    let lines: [String]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("The job so far")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone() }
                }
            }
        }
    }
}
