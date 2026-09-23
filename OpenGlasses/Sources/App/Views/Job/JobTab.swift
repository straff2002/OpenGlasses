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
        // The flow and the send queue are what publish changes the tab draws; `AppState` does not
        // republish its children, so the content view observes both directly.
        JobTabContent(flow: appState.guidedJobFlow, sends: appState.jobSends)
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
    @ObservedObject var sends: JobSendService
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
    /// Non-nil while the evidence review is in front of the technician (Plan FO P2a). It holds the
    /// selection being edited, so nothing is written onto the session until they finish.
    @State private var reviewingEvidence: EvidenceSelection?
    /// The customer sign-off step, once the evidence has been decided and before the job closes
    /// (Plan FO P2c). It carries the summary the customer will be shown and the evidence decision
    /// that is waiting on it, so nothing is written onto the session until the job actually closes.
    @State private var signOffStep: SignOffStep?
    /// The step waiting for the evidence review to finish getting out of the way. Two sheets
    /// raised in one runloop turn is how the second one silently never appears, so the review's
    /// dismissal is what promotes this into `signOffStep`.
    @State private var pendingSignOff: SignOffStep?
    @State private var problem: String?
    /// Re-read on a timer rather than every frame — see `JobClock`.
    @State private var clock = Date()

    private var model: JobTabModel { JobTabModel(host: sessions, flow: flow) }

    /// The staged sends, when there are any (Plan FO P3b).
    ///
    /// Read fresh each pass rather than held: a send asked for in the car lands in the queue while
    /// this screen may already be up, and the card has to appear without a navigation.
    private var sendCard: JobSendQueueSection? {
        guard let headline = sends.cardHeadline else { return nil }
        return JobSendQueueSection(
            entries: sends.staged,
            headline: headline,
            onSend: { sends.present($0) },
            onSendAll: { _ = sends.sendAll() },
            onCancel: { sends.cancel(id: $0.id) })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch model.state {
                case .noJob(let empty):
                    NoActiveJobView(empty: empty, model: model, search: $search,
                                    typedReference: $typedReference,
                                    onStart: startJob,
                                    onOpenPastJob: { path.append(.pastJob(sessionId: $0)) },
                                    sendCard: sendCard)
                case .running(let job), .paused(let job):
                    ActiveJobView(job: job, model: model,
                                  typedReference: $typedReference,
                                  leaveThread: $leaveThread,
                                  unitQuestion: model.unitQuestion,
                                  evidence: model.evidenceReview,
                                  evidenceSelection: liveSelection,
                                  onAnswerUnit: { action in Task { await model.answer(action) } },
                                  onPauseResume: pauseOrResume,
                                  onAddPhoto: addPhoto,
                                  clips: appState.jobClips,
                                  onRecordClip: recordClip,
                                  onStopClip: stopClip,
                                  onSharePhotos: shareSelectedPhotos,
                                  onOpenPrivacySettings: { appState.requestedTab = .settings },
                                  onOpenConversation: openConversation,
                                  onReadBack: readBackTheJob,
                                  onClose: startClosing,
                                  sendCard: sendCard)
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
        // A job with no photos on it closes the way it always has: one question, one tap.
        .confirmationDialog("Close this job?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("Close job", role: .destructive) { beginSignOff(evidence: nil) }
            Button("Keep working", role: .cancel) {}
        } message: {
            Text("Time stops, the record is finished, and the job's conversation is closed with it. You can still send the report afterwards.")
        }
        // A job that took photos gets the review first — it carries the same warning in its
        // footer, so the confirmation is not asked twice.
        .sheet(isPresented: Binding(get: { reviewingEvidence != nil },
                                    set: { if !$0 { reviewingEvidence = nil } }),
               onDismiss: {
                   if let waiting = pendingSignOff {
                       pendingSignOff = nil
                       signOffStep = waiting
                   }
               }) {
            if let review = model.evidenceReview {
                JobEvidenceReviewView(
                    review: review,
                    // The sheet is only up while there is one, so the fallback is never reached;
                    // it is here because a `Binding` cannot be optional.
                    selection: Binding(get: { reviewingEvidence ?? model.evidenceSelection() },
                                       set: { reviewingEvidence = $0
                                              flow.updateEvidenceReview(selection: $0) }),
                    onReadOutLoud: { Task { await flow.readEvidenceOutLoud() } },
                    onClose: { beginSignOff(evidence: reviewingEvidence?.confirmed()) },
                    onSkip: { beginSignOff(evidence: EvidenceSelection.skipped()) },
                    onShare: {
                        appState.presentEvidenceShare(
                            review.shareURLs(for: reviewingEvidence ?? model.evidenceSelection()))
                    },
                    onCancel: { endReview() })
                // The spoken half of the same step. The flow owns it, because the flow is where an
                // utterance is offered to the app before the model sees it — so "include all" is
                // app behaviour rather than something the model has to be trusted to understand.
                .onAppear {
                    flow.beginEvidenceReview(
                        selection: reviewingEvidence ?? model.evidenceSelection(),
                        items: review.items)
                }
                .onChange(of: flow.evidenceReview) { _, spoken in
                    guard let spoken else { return }
                    reviewingEvidence = spoken.selection
                    // "Include all", "skip photos" and the end of the read-out all settle the
                    // answer, and the answer is what closes the job.
                    if spoken.isSettled { beginSignOff(evidence: spoken.outcome) }
                }
            }
        }
        // The technician's step: what the customer would be asked to agree to, and the three
        // answers — hand the phone over, record a decline, or close with nothing signed. The
        // customer's own screen is presented from inside it.
        .sheet(item: $signOffStep) { step in
            JobSignOffStepView(
                summaryLines: step.lines,
                jobNumber: step.jobNumber,
                dateLine: step.dateLine,
                organisationName: Config.organizationDisplayName,
                required: model.signOffRequired,
                onSignOff: { signOff, png, strokes in
                    model.recordSignOff(signOff, pngData: png, strokeData: strokes)
                    closeJob(evidence: step.evidence)
                },
                onDeclined: { reason in
                    model.recordSignOff(CustomerSignOff(
                        customerName: "", method: .declined, declinedReason: reason,
                        summaryLines: step.lines))
                    closeJob(evidence: step.evidence)
                },
                onSkip: { closeJob(evidence: step.evidence) },
                onCancelledHandOver: { model.signOffCancelled(sessionId: nil) },
                onCancel: { signOffStep = nil })
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

    /// The selection the open job's Photos section draws against. Read fresh each time rather than
    /// held: a photo taken while this screen is up has to appear on it.
    private var liveSelection: Binding<EvidenceSelection> {
        Binding(get: { model.evidenceSelection() },
                set: { model.applyEvidenceSelection($0) })
    }

    /// Closing a job that took photos asks which of them go out first; one that took none closes
    /// the way it always has.
    private func startClosing() {
        guard let review = model.evidenceReview, !review.isEmpty else {
            confirmingClose = true
            return
        }
        reviewingEvidence = model.evidenceSelection()
    }

    private func addPhoto(_ origin: JobMediaItem.Origin, _ data: Data) {
        let outcome = appState.jobPhotoEvidence.attach(imageData: data, origin: origin)
        if let trouble = outcome.problem { problem = trouble }
    }

    /// Start a clip from the button. The refusal is shown rather than swallowed: a record button
    /// that does nothing when the glasses are asleep is the defect this phase is here to avoid.
    private func recordClip() {
        if case .failure(let refusal) = appState.startJobClip() {
            problem = refusal.spoken
        }
    }

    private func stopClip() {
        Task {
            let finished = await appState.stopJobClip()
            if finished == nil { problem = "The clip stopped, but nothing could be saved." }
        }
    }

    private func shareSelectedPhotos() {
        guard let review = model.evidenceReview else { return }
        appState.presentEvidenceShare(review.shareURLs(for: model.evidenceSelection()))
    }

    /// Put the review away without closing the job — and stop the flow listening for "yes".
    private func endReview() {
        reviewingEvidence = nil
        flow.endEvidenceReview()
    }

    /// The evidence is decided; ask about the customer's signature before anything closes.
    ///
    /// The summary is taken here, once, and carried through both screens: the sheet shows exactly
    /// the lines the digest will be taken over, so what the customer read and what the record
    /// proves they read cannot drift apart. A job that can produce no record has nothing to put in
    /// front of anybody, and closes the way it always did.
    private func beginSignOff(evidence: EvidenceSelection?) {
        guard let lines = model.customerSummaryLines, let heading = model.signOffHeading else {
            closeJob(evidence: evidence)
            return
        }
        let step = SignOffStep(lines: lines, jobNumber: heading.jobNumber,
                               dateLine: heading.dateLine, evidence: evidence)
        if reviewingEvidence != nil {
            pendingSignOff = step
            endReview()
        } else {
            signOffStep = step
        }
    }

    private func closeJob(evidence: EvidenceSelection? = nil) {
        do {
            let closed = try model.closeJob(evidence: evidence)
            signOffStep = nil
            endReview()
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

/// The customer sign-off step, while it is waiting on an answer (Plan FO P2c).
///
/// It holds the evidence decision the close is carrying, so that answering the sign-off is what
/// finally writes anything: a technician who backs out of this step has changed nothing at all.
struct SignOffStep: Identifiable, Equatable {
    /// The customer summary, taken once when the step opened. Both screens and the digest use
    /// exactly this, so what was read and what was recorded cannot differ.
    let lines: [String]
    let jobNumber: String
    let dateLine: String
    let evidence: EvidenceSelection?

    var id: String { jobNumber + dateLine }
}
