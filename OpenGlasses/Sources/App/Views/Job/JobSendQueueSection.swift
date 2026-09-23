import SwiftUI

/// The reports waiting for a thumb, at the top of the Job tab (Plan FO §6, P3b).
///
/// A send asked for in the car on a channel that needs a composer cannot complete until the phone
/// is in the technician's hand. This is that moment, and it is deliberately the first thing on the
/// tab: a report nobody sent is the one thing a technician must not discover a week later.
///
/// **Send all is an offer, not a decision.** It opens each composer in turn; a cancelled one stays
/// queued, because dismissing a composer is not the same as saying the report should not go.
struct JobSendQueueSection: View {

    let entries: [QueuedSend]
    let headline: String
    let onSend: (QueuedSend) -> Void
    let onSendAll: () -> Void
    let onCancel: (QueuedSend) -> Void

    var body: some View {
        Section {
            Text(headline)
                .font(.headline)
                .foregroundStyle(OGTheme.accentLabelToken.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.summaryLine)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(waitingLine(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)

                Button { onSend(entry) } label: {
                    Text("Send \(entry.documentKind.label.lowercased())")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                               alignment: .leading)
                }
                .accessibilityHint("Opens it filled in. Nothing leaves the phone until you tap Send there.")

                Button(role: .destructive) { onCancel(entry) } label: {
                    Text("Don't send this one")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                               alignment: .leading)
                }
            }

            if entries.count > 1 {
                Button { onSendAll() } label: {
                    Text("Send all")
                        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget,
                               alignment: .leading)
                }
                .accessibilityHint("Opens each one in turn. Anything you cancel stays here.")
            }
        } header: {
            Text("Ready to send")
        } footer: {
            Text("Asked for by voice. These need a composer, which only opens on the phone — so nothing has gone yet.")
        }
    }

    /// What one entry is waiting on, in words rather than a colour.
    private func waitingLine(_ entry: QueuedSend) -> String {
        var line = "Queued \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))"
        let reason = SpokenSendPolicy.stagingReason(for: entry.channel)
        if !reason.isEmpty { line += " · \(reason)" }
        if let failure = entry.failureReason, !failure.isEmpty { line += " · \(failure)" }
        return line
    }
}
