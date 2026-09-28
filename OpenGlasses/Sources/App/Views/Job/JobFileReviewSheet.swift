import SwiftUI

/// A job file, in front of the technician before anything is added (Plan FO §8, P3c).
///
/// What the file says, whether it is signed and by whom, and **one** button. A job number already
/// on this phone turns that button into a question — update the one there, or keep both — and is
/// never a silent overwrite. Nothing here starts a job.
@MainActor
struct JobFileReviewSheet: View {

    @ObservedObject var service: JobFileService
    /// Called after a job is added, to take the technician to where it went.
    var onAdded: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                switch service.stage {
                case .idle:
                    EmptyView()
                case .review(let review):
                    reviewSections(review)
                case .refused(let message):
                    Section {
                        OGStatusLabel(message, kind: .error)
                    } footer: {
                        Text("Nothing was added.")
                    }
                case .added(let title):
                    Section {
                        OGStatusLabel("\(title) added to upcoming jobs.", kind: .ok)
                        Button("Show upcoming jobs") {
                            onAdded()
                            service.dismiss()
                            dismiss()
                        }
                    }
                }
            }
            .ogFormStyle()
            .navigationTitle("Job file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReviewing ? "Cancel" : "Close") {
                        service.dismiss()
                        dismiss()
                    }
                }
            }
        }
    }

    private var isReviewing: Bool {
        if case .review = service.stage { return true }
        return false
    }

    @ViewBuilder
    private func reviewSections(_ review: JobFileReview) -> some View {
        Section {
            OGStatusLabel(review.signatureLine, kind: review.isSigned ? .ok : .warn,
                          systemImage: review.isSigned ? "checkmark.seal.fill" : "exclamationmark.triangle")
            if let claimed = review.claimedIssuer {
                Text("The file says it is from \u{201C}\(claimed)\u{201D}. That is what the file claims, not something this phone could check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Who it's from")
        }

        Section {
            ForEach(review.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(line.value)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("The job")
        } footer: {
            Text("Anything the office left out stays empty. The job is added to Upcoming on the Job tab; it doesn't start, and nothing is sent.")
        }

        Section {
            if let question = review.duplicateQuestion {
                Text(question).font(.callout)
                Button("Update \(review.duplicate?.title ?? "that job")") { service.accept(.update) }
                    .accessibilityHint("Replaces what's on this phone with what the file says.")
                Button("Keep both") { service.accept(.keepBoth) }
                    .accessibilityHint("Adds this file as a second upcoming job with the same number.")
            } else {
                Button {
                    service.accept(.add)
                } label: {
                    Text("Add to upcoming jobs")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.ogProminent)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }
}
