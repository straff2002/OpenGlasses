import SwiftUI

/// The coaching steps experts sent for the open job (Plan KM §5, P3): who they are credited to,
/// how many steps, which touch the safety rules, and the two things the technician can do — walk
/// them (or say "walk Sam's steps"), and, where allowed, offer them for the team's review. Draws
/// nothing on a job that received none.
struct JobCoachingSection: View {
    @ObservedObject private var sessions: FieldSessionService = .shared
    @State private var message: String?

    var body: some View {
        let coaching = sessions.coachingOnJob
        if !coaching.isEmpty {
            Section {
                ForEach(coaching) { received in
                    row(received)
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Coaching from an expert")
            } footer: {
                Text("Read to you as the expert wrote them, one step at a time, with any safety rule a step touches read first. They stay with this job and never join your procedures.")
            }
        }
    }

    @ViewBuilder
    private func row(_ received: ExpertCoachingReceived) -> some View {
        let count = received.steps.count
        VStack(alignment: .leading, spacing: 4) {
            Text(received.credit)
            Text(count == 1 ? "1 step" : "\(count) steps")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !received.flaggedSteps.isEmpty {
                Label(received.flaggedSteps.count == 1
                      ? "1 step touches the safety rules"
                      : "\(received.flaggedSteps.count) steps touch the safety rules",
                      systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(OGTheme.warnLabel)
            }
        }
        .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)

        if sessions.activeProcedureId == nil, sessions.coachingWaiting.contains(where: { $0.coachingId == received.coachingId }) {
            Button {
                walk(received)
            } label: {
                Text("Walk these steps")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Starts the walkthrough. The assistant reads each step and records your readings against it.")
        }

        if case .offered = CoachingTeamLearning.decide(received, organisationExperts: ExpertListStore.shared.organizationExperts) {
            Button {
                offer(received)
            } label: {
                Text("Offer as a team learning")
                    .frame(maxWidth: .infinity, minHeight: OGMetrics.minTouchTarget, alignment: .leading)
            }
            .accessibilityHint("Files the steps for your office's review, credited to the expert. They aren't used until approved.")
        } else if received.offeredAsTeamLearningAt != nil {
            Text("Offered for the team's review.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func walk(_ received: ExpertCoachingReceived) {
        do {
            let step = try sessions.startProcedure(id: received.procedureId)
            message = "Walking \(received.credit)'s steps. \(step.title): ask the assistant to read it."
        } catch {
            message = error.localizedDescription
        }
    }

    private func offer(_ received: ExpertCoachingReceived) {
        switch LearningCandidateService.shared.offerCoaching(coachingId: received.coachingId) {
        case .success: message = "Offered for your office's review, credited to \(received.expert.name)."
        case .failure(let refusal): message = refusal.spoken
        }
    }
}
