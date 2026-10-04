import SwiftUI

/// What has arrived from the office, in a sentence: a job received and ready for review, or one
/// that could not be added and why. Shows nothing while nothing has arrived; the connection's own
/// row says whether the phone is waiting for the office.
struct OfficeManagedJobIntakeRow: View {
    @ObservedObject var intake: OfficeManagedJobIntake

    var body: some View {
        if let status = OfficeManagedJobIntake.status(intake.state) {
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
