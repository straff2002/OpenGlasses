import SwiftUI

/// How this phone's connection to its office stands, in a sentence: connected directly or through
/// a relay, waiting, paused, or stopped and what to do about it. Shows nothing in a build without
/// the office transport.
struct OfficeFieldConnectionRow: View {
    @ObservedObject var connection: OfficeFieldConnection

    var body: some View {
        if let status = OfficeFieldConnectionPolicy.status(connection.state) {
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
