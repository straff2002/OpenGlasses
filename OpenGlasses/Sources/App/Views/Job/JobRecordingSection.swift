import SwiftUI

/// "Record this job" on a job's page, and where that recording stands with the office (Plan HE).
///
/// Shown only where there is an office to record for: in a build with the office transport, on a
/// phone that is paired with one. On any other phone this draws nothing at all.
///
/// The recording has one way off the phone and it is not on this screen. There is no share, no
/// save and no attach here — only start, pause, mark, stop, and delete.
struct JobRecordingSection: View {
    /// The job this page is for.
    let sessionID: String?
    /// Whether that job is the open one. Only an open job can be recorded.
    var isOpenJob = true
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let sessionID, let coordinator = appState.jobRecordings, let sync = appState.officeJobRecordings {
            JobRecordingRows(sessionID: sessionID, isOpenJob: isOpenJob, coordinator: coordinator, sync: sync)
        }
    }
}

private struct JobRecordingRows: View {
    let sessionID: String
    let isOpenJob: Bool
    @ObservedObject var coordinator: JobRecordingCoordinator
    @ObservedObject var sync: JobRecordingSyncService

    @State private var showingConsent = false
    @State private var confirmingDelete = false
    /// Why the last tap did nothing, when it did nothing.
    @State private var problem: String?
    /// The line shown at each start.
    @State private var reminder: String?

    private var row: JobRecordingSyncService.Row? { sync.rows.first { $0.sessionID == sessionID } }
    private var isRecordingHere: Bool { coordinator.status.sessionID == sessionID }
    /// Stopped, and being transcribed and sealed.
    private var isBeingPrepared: Bool { coordinator.preparing.contains(sessionID) }

    /// What last happened to this job's recording. Another job's is not shown here.
    private var noteForThisJob: String? {
        coordinator.lastNoteSessionID == sessionID ? coordinator.lastNote : nil
    }

    private var hasSomethingToShow: Bool {
        if isRecordingHere || isBeingPrepared || row != nil { return true }
        guard isOpenJob else { return coordinator.hasUnsealedRecording(sessionID: sessionID) }
        return coordinator.unsealed != nil || coordinator.verdict != .notOffered
    }

    var body: some View {
        Group {
            if hasSomethingToShow {
                Section {
                    if isRecordingHere {
                        running
                    } else if isBeingPrepared {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing the recording.")
                                .font(.callout)
                        }
                    } else if let row {
                        sent(row)
                    } else if !isOpenJob {
                        // A finished job whose recording is still to be sealed.
                        notYetSealed(.waitingToPrepare)
                    } else if let unsealed = coordinator.unsealed {
                        notYetSealed(unsealed)
                    } else {
                        offer
                    }
                    if let line = problem ?? (isRecordingHere ? reminder : noteForThisJob) {
                        Text(verbatim: line)
                            .font(.caption)
                            .foregroundStyle(problem == nil ? Color.secondary : OGTheme.warnLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    if isRecordingHere || coordinator.verdict == .available {
                        Text("Goes to your organisation's office and nowhere else. It can't be shared or saved to Photos from this phone.")
                    }
                }
            }
        }
        .task { await coordinator.refresh() }
        .sheet(isPresented: $showingConsent) {
            RecordingConsentSheet(
                onAcknowledge: {
                    showingConsent = false
                    Task {
                        if await coordinator.acknowledgeConsent() { await begin() }
                    }
                },
                onCancel: { showingConsent = false })
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete recording", role: .destructive) {
                guard let row else { return }
                Task {
                    try? await sync.delete(bundleID: row.id)
                    await coordinator.refresh()
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            if let row, sync.deletionNeedsConfirmation(bundleID: row.id) {
                Text(verbatim: RetentionDecision.unacknowledgedRecordingDeletionWarning)
            } else {
                Text("The office has this recording. This removes what is left of it from this phone.")
            }
        }
    }

    // MARK: - Not recording yet

    @ViewBuilder
    private var offer: some View {
        switch coordinator.verdict {
        case .available:
            choice("Record this job") { Task { await beginAfterConsent() } }
                .accessibilityHint("Records sound and pictures from the glasses for your office. You are told what that means first.")
        case .unavailable(let reason):
            choice("Record this job") {}
                .disabled(true)
            Text(verbatim: reason.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .notOffered:
            EmptyView()
        }
    }

    @ViewBuilder
    private func notYetSealed(_ unsealed: JobRecordingCoordinator.Unsealed) -> some View {
        switch unsealed {
        case .interrupted:
            Text("A recording of this job was interrupted. What had been recorded is saved.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            choice("Carry on recording") { Task { await beginAfterConsent() } }
            choice("Finish the recording") { Task { await coordinator.finishInterrupted() } }
        case .waitingToPrepare:
            Text("The recording is saved on this phone and will be prepared for the office.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - While it runs

    @ViewBuilder
    private var running: some View {
        switch coordinator.status {
        case .recording:
            statusLine("Recording", detail: sizeAndTime)
            choice("Mark this moment") { coordinator.mark() }
                .accessibilityHint("Tells the office to look here.")
            choice("Pause recording") { Task { await coordinator.pause() } }
            stopButton
        case .paused:
            statusLine("Recording paused", detail: sizeAndTime)
            choice("Carry on recording") {
                Task { problem = await coordinator.resume()?.explanation }
            }
            stopButton
        case .waitingForVideo:
            statusLine("Waiting for the glasses", detail: "They stopped sending video. What was recorded is saved, and recording carries on when they come back.")
            stopButton
        case .idle:
            EmptyView()
        }
    }

    private var sizeAndTime: String {
        JobClipRecorder.clock(coordinator.elapsed) + " · "
            + ByteCountFormatter.string(fromByteCount: coordinator.recordedBytes, countStyle: .file)
    }

    private func statusLine(_ title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var stopButton: some View {
        Button("Stop recording", role: .destructive) {
            Task { await coordinator.stop() }
        }
        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        .accessibilityHint("Stops and saves the recording, and gets it ready to go to the office.")
    }

    // MARK: - Once it is sealed

    @ViewBuilder
    private func sent(_ row: JobRecordingSyncService.Row) -> some View {
        Text(verbatim: JobRecordingSyncService.words(row))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        switch row.phase {
        case .expired, .failed:
            choice("Keep waiting for the office") {
                Task { try? await sync.keepWaiting(bundleID: row.id) }
            }
        default:
            EmptyView()
        }
        Button("Delete recording", role: .destructive) { confirmingDelete = true }
            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
    }

    // MARK: - Starting

    /// Start, showing the consent first when it has not been acknowledged.
    private func beginAfterConsent() async {
        problem = nil
        if await coordinator.consentStands() {
            await begin()
        } else if coordinator.verdict == .available {
            showingConsent = true
        } else {
            await begin()   // says why not
        }
    }

    private func begin() async {
        switch await coordinator.start() {
        case .success(let line):
            reminder = line
            problem = nil
        case .failure(.consentRequired):
            showingConsent = true
        case .failure(let refusal):
            problem = refusal.explanation
        }
    }

    private func choice(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
        }
    }
}

/// What recording a job means, read before the first recording (Plan HE §5). The words are
/// `RecordingConsent`'s; this only shows them and hands back the answer.
struct RecordingConsentSheet: View {
    let onAcknowledge: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(RecordingConsent.points(), id: \.self) { point in
                        Text(verbatim: point)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                    }
                }
                Section {
                    Button(action: onAcknowledge) {
                        Text(verbatim: RecordingConsent.acknowledgeTitle)
                            .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
                    }
                } footer: {
                    Text("You are asked this once. Each recording after that starts with a short reminder.")
                }
            }
            .ogFormStyle()
            .navigationTitle(Text(verbatim: RecordingConsent.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onCancel)
                }
            }
        }
    }
}
