import SwiftUI

/// Phone-side status for the offline field queue (Plan T): connectivity, queue depth, per-op
/// state, and conflicts needing attention. The durable record is the queue itself; this is the
/// glanceable window onto it for the technician back in signal.
struct SyncStatusView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var engine: SyncEngine
    @ObservedObject private var reachability: Reachability
    @State private var ops: [QueuedOp] = []

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
                        .foregroundStyle(reachability.isOnline ? .green : .orange)
                        .labelStyle(.titleAndIcon)
                }
                HStack { Text("Pending"); Spacer(); Text("\(appState.offlineQueue.pendingCount)").foregroundStyle(.secondary) }
                if appState.offlineQueue.conflictCount > 0 {
                    HStack { Text("Conflicts"); Spacer(); Text("\(appState.offlineQueue.conflictCount)").foregroundStyle(.orange) }
                }
                Button {
                    Task { await engine.flush(); reload() }
                } label: {
                    Label(engine.isFlushing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(engine.isFlushing || !reachability.isOnline || appState.offlineQueue.pendingCount == 0)
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
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Refresh", action: reload) } }
        .onAppear(perform: reload)
    }

    private func reload() { ops = appState.offlineQueue.all(limit: 100) }

    private func label(for kind: OpKind) -> String {
        switch kind {
        case .logEntry:     return "Log entry"
        case .photoUpload:  return "Photo upload"
        case .llmGrounding: return "Deferred question"
        case .auditExport:  return "Audit export"
        }
    }

    @ViewBuilder
    private func stateBadge(_ state: OpState) -> some View {
        switch state {
        case .pending:  badge("Pending", "clock", .gray)
        case .inFlight: badge("Sending", "arrow.up.circle", .blue)
        case .done:     badge("Synced", "checkmark.circle", .green)
        case .conflict: badge("Conflict", "exclamationmark.triangle", .orange)
        case .failed:   badge("Failed", "xmark.circle", .red)
        }
    }

    private func badge(_ text: String, _ systemImage: String, _ color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}
