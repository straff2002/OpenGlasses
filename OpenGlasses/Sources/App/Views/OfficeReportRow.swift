import SwiftUI

/// What is still on its way to the office: records it has not confirmed, or records it has whose
/// documents are still travelling. Shows nothing when there is nothing on the way.
struct OfficeReportRow: View {
    @ObservedObject var reports: OfficeReportService

    var body: some View {
        if let status = OfficeReportService.status(reports.summary) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: status.title)
                    if let detail = status.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: status.systemImage)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
