import SwiftUI

/// Shows all network activity categorized by destination, with Meta calls highlighted.
struct NetworkMonitorView: View {
    @ObservedObject private var monitor = NetworkMonitorService.shared

    var body: some View {
        List {
            // MARK: Summary
            Section {
                summaryRow(
                    category: .meta,
                    count: monitor.metaEntries.count,
                    bytes: monitor.metaBytesSent
                )
                summaryRow(
                    category: .aiProvider,
                    count: monitor.aiEntries.count,
                    bytes: monitor.aiEntries.reduce(0) { $0 + $1.requestSize }
                )
                summaryRow(
                    category: .appService,
                    count: monitor.appEntries.count,
                    bytes: monitor.appEntries.reduce(0) { $0 + $1.requestSize }
                )
                summaryRow(
                    category: .other,
                    count: monitor.otherEntries.count,
                    bytes: monitor.otherEntries.reduce(0) { $0 + $1.requestSize }
                )
            } header: {
                Text("Data Sent by Category")
            } footer: {
                Text("Total: \(monitor.entries.count) requests, \(formatBytes(monitor.totalBytesSent)) sent, \(formatBytes(monitor.totalBytesReceived)) received.")
            }

            // MARK: Meta calls (if any)
            if !monitor.metaEntries.isEmpty {
                Section {
                    ForEach(monitor.metaEntries.prefix(20)) { entry in
                        requestRow(entry)
                    }
                } header: {
                    Text("Meta / Facebook Calls")
                } footer: {
                    Text("These are requests made by the Meta Wearables SDK. Some internal SDK calls may not appear here.")
                }
            }

            // MARK: Recent requests
            Section {
                if monitor.entries.isEmpty {
                    Text("No network activity yet. Use the app and requests will appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.entries.prefix(50)) { entry in
                        requestRow(entry)
                    }
                }
            } header: {
                Text("All Recent Requests")
            }
        }
        .navigationTitle("Network Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    monitor.clear()
                }
            }
        }
    }

    private func summaryRow(category: NetworkCategory, count: Int, bytes: Int) -> some View {
        HStack {
            Image(systemName: category.icon)
                .foregroundStyle(category == .meta ? .orange : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .lineLimit(1)
                Text("\(count) requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(bytes))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func requestRow(_ entry: NetworkEntry) -> some View {
        HStack {
            Circle()
                .fill(statusColor(entry.statusCode))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host)
                    .font(.footnote)
                    .lineLimit(1)
                Text("\(entry.method) \(entry.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if entry.statusCode > 0 {
                    Text("\(entry.statusCode)")
                        .font(.caption)
                        .foregroundStyle(entry.statusCode >= 400 ? .red : .secondary)
                }
                Text(timeAgo(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusColor(_ code: Int) -> Color {
        if code == 0 { return .gray }
        if code < 300 { return .green }
        if code < 400 { return .orange }
        return .red
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}
