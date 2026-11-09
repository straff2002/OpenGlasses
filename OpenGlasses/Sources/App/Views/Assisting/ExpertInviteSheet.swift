import SwiftUI

/// What opening an invite shows on the expert's phone (Plan KW §4): the card form, with the
/// invite's line above it. Send Card answers it; Not Now keeps it until it runs out; Decline drops
/// it and sends nothing. It unlocks nothing else.
struct ExpertInviteSheet: View {
    @ObservedObject var service: AssistingService
    let invite: OpenInvite
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDecline = false

    var body: some View {
        NavigationStack {
            ExpertCardView(cards: service.cards, answering: invite.invite,
                           onChange: { service.refreshPresence() },
                           onAnswered: {
                               service.answerInvite(invite.id)
                               dismiss()
                           })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not Now") { dismiss() }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Decline", role: .destructive) { confirmingDecline = true }
                    }
                }
                .confirmationDialog("Decline this invite?", isPresented: $confirmingDecline,
                                    titleVisibility: .visible) {
                    Button("Decline", role: .destructive) {
                        service.declineInvite(invite.id)
                        dismiss()
                    }
                } message: {
                    Text("Nothing is sent. \(invite.invite.senderName) won't hear from the app that you declined.")
                }
        }
    }
}
