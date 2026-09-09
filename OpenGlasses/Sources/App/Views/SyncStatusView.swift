import SwiftUI

/// Phone-side status for the offline field queue (Plan T): connectivity, queue depth, per-op
/// state, and conflicts needing attention. The durable record is the queue itself; this is the
/// glanceable window onto it for the technician back in signal.
struct SyncStatusView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var engine: SyncEngine
    @ObservedObject private var reachability: Reachability
    @State private var ops: [QueuedOp] = []
    /// The job records and stock checks that have not reached anybody (Plan EM P2).
    @State private var records: [QueuedRecordRow] = []

    init(engine: SyncEngine, reachability: Reachability) {
        _engine = ObservedObject(wrappedValue: engine)
        _reachability = ObservedObject(wrappedValue: reachability)
    }

    var body: some View {
        List {
            Section("Sync") {
                HStack {
                    Text("Connection")
                    Spacer()
                    Label(reachability.isOnline ? "Online" : "Offline",
                          systemImage: reachability.isOnline ? "wifi" : "wifi.slash")
                        .foregroundStyle(reachability.isOnline ? OGTheme.okLabel : OGTheme.warnLabel)
                        .labelStyle(.titleAndIcon)
                }
                HStack { Text("Pending"); Spacer(); Text("\(appState.offlineQueue.pendingCount)").foregroundStyle(.secondary) }
                if appState.offlineQueue.conflictCount > 0 {
                    HStack { Text("Conflicts"); Spacer(); Text("\(appState.offlineQueue.conflictCount)").foregroundStyle(OGTheme.warnLabel) }
                }
                Button {
                    Task { await engine.flush(); reload() }
                } label: {
                    Label(engine.isFlushing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(engine.isFlushing || !reachability.isOnline || appState.offlineQueue.pendingCount == 0)
            }

            if !records.isEmpty {
                Section {
                    ForEach(records) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title).font(.subheadline)
                                Spacer()
                                stateBadge(row.state)
                            }
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if row.attempts > 0 {
                                Text("\(row.attempts) attempt\(row.attempts == 1 ? "" : "s") so far")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 16) {
                                Button("Retry") { retry(row) }
                                    .buttonStyle(.bordered)
                                    .font(.subheadline)
                                if row.canDeliver {
                                    Button("Send by email instead") {
                                        appState.deliverQueuedRecord(row)
                                    }
                                    .buttonStyle(.bordered)
                                    .font(.subheadline)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Job Reports Not Yet Sent")
                } footer: {
                    Text("A record stays here until the office has it. Retry sends it again through the queue; sending it by email opens the composer with the record in the body, and you tap Send.")
                }
            }

            Section("Queue") {
                if ops.isEmpty {
                    Text("Nothing queued — you're all caught up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ops) { op in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: op.kind)).font(.subheadline)
                                Text(op.sessionId).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            stateBadge(op.state)
                        }
                    }
                }
            }
        }
        .navigationTitle("Field Sync")
        .navigationBarTitleDisplayMode(.inline)
        .ogFormStyle()
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Refresh", action: reload) } }
        .onAppear(perform: reload)
    }

    private func reload() {
        ops = appState.offlineQueue.all(limit: 100)
        records = QueuedRecordRows.rows(from: ops)
    }

    /// Put a row back in the queue and drain it. `attempts` resets, because a technician asking
    /// again is a fresh try, not the seventh of six.
    private func retry(_ row: QueuedRecordRow) {
        appState.offlineQueue.mark(row.id, state: .pending, attempts: 0)
        Task {
            await appState.syncEngine.flush()
            reload()
        }
    }

    private func label(for kind: OpKind) -> String {
        switch kind {
        case .logEntry:      return "Log entry"
        case .photoUpload:   return "Photo upload"
        case .llmGrounding:  return "Deferred question"
        case .auditExport:   return "Audit export"
        case .captureRecord: return "Capture record"
        case .workRecord:    return "Work record"
        case .partsRequest:  return "Parts request"
        case .subjectErasure: return "Deletion request"
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: OpState) -> some View {
        switch state {
        case .pending:  badge("Pending", "clock", .gray)
        case .inFlight: badge("Sending", "arrow.up.circle", .blue)
        case .done:     badge("Synced", "checkmark.circle", OGTheme.okLabel)
        case .conflict: badge("Conflict", "exclamationmark.triangle", OGTheme.warnLabel)
        case .failed:   badge("Failed", "xmark.circle", OGTheme.errorLabel)
        }
    }

    private func badge(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}
