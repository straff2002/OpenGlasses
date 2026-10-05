import SwiftUI

/// What the office has said about this phone's place in it. A check-in and its renewal need
/// nobody and show nothing; a removal is said, in the office's own terms, and so is a check-in
/// the office never answered.
struct OfficeCheckInRow: View {
    @ObservedObject var checkIn: OfficeCheckInService

    var body: some View {
        if let status = OfficeCheckInService.status(checkIn.state) {
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
