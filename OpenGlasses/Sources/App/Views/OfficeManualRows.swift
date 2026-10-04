import SwiftUI

/// The manuals the office has assigned to this phone and where each is: waiting for the office,
/// waiting for Wi-Fi, still downloading, ready, or not installed and why.
struct OfficeManualRows: View {
    @ObservedObject var manuals: OfficeManualService

    var body: some View {
        ForEach(manuals.rows) { row in
            let status = OfficeManualService.status(row)
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
