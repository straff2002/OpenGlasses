import SwiftUI

/// Inspectable audit trail for remote-invoke exchanges (Plan BH): what the gateway agent asked
/// for, and what happened — allowed, denied (with reason), declined by the user, or failed.
struct RemoteInvokeAuditView: View {
    @ObservedObject var service: RemoteInvokeService

    var body: some View {
        List {
            if service.auditLog.isEmpty {
                Text("No remote commands yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.auditLog) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.action)
                                .font(.body.monospaced())
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            // Per-origin attribution (Plan BN P2): tag the caller so a specific
                            // gateway/peer's activity is traceable in the log.
                            Text(entry.origin)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.quaternary))
                            Text(entry.disposition)
                                .font(.caption)
                                .foregroundStyle(entry.disposition == "allowed" ? OGTheme.okLabel : OGTheme.warnLabel)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Remote Activity")
        .toolbar {
            if !service.auditLog.isEmpty {
                Button("Clear") { service.clearAudit() }
            }
        }
    }
}
