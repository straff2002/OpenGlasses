import SwiftUI

/// The organisation's review of an expert's card before it goes on the list (Plan KM P2). Opened
/// from an `.ogexpert` file or a scanned code. The card fills the name, number, FaceTime handle,
/// channel and specialties; the organisation sets the kind, hours and any rate on the entry after,
/// because the card never carries them.
struct ExpertCardImportSheet: View {
    let pending: ExpertCardInbox.Pending
    let onDone: () -> Void
    @State private var outcome: String?

    private var entitled: Bool { FieldAssistEntitlement.shared.has(.fieldWork) }

    /// The invite this phone sent that the card answers (Plan KW §4), while it is still open.
    private var answered: SentExpertInvite? {
        guard let id = pending.answering else { return nil }
        return ExpertListStore.shared.sentInvites().first { $0.id == id }
    }

    var body: some View {
        let card = pending.card
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: card.name)
                    if let phone = card.phone { LabeledContent("Phone", value: phone) }
                    if let handle = card.faceTimeHandle { LabeledContent("FaceTime", value: handle) }
                    if !card.specialties.isEmpty {
                        LabeledContent("Specialties", value: card.specialties.joined(separator: ", "))
                    }
                } header: {
                    Text("Expert card")
                } footer: {
                    if let answered {
                        Text("This answers the invite you sent \(answered.inviteeName.isEmpty ? "" : answered.inviteeName + " ")on \(answered.sentAt.formatted(date: .abbreviated, time: .omitted)).")
                    }
                }

                if !card.licences.isEmpty {
                    Section {
                        ForEach(card.licences, id: \.self) { Text($0) }
                    } header: {
                        Text("Licensed for, as they say")
                    } footer: {
                        Text("Check these against your own records. They aren't stored on the list.")
                    }
                }

                Section {
                    if let outcome {
                        Text(outcome)
                    } else if entitled {
                        Button("Add to Experts") {
                            let result = ExpertCardImport.apply(card, to: .shared)
                            outcome = ExpertCardImport.message(result, name: card.name)
                            if case .refused = result {} else if let id = pending.answering {
                                ExpertListStore.shared.removeSentInvite(id: id)
                            }
                        }
                    } else {
                        Text("Experts are part of Field Assist. Unlock Field Assist to add this expert to your list.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Their replies to the jobs you send them carry this card, so their time matches this entry exactly. Their kind, hours and any rate are yours to set; a card never carries a rate.")
                }
            }
            .ogFormStyle()
            .navigationTitle("Add an Expert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(outcome == nil ? "Cancel" : "Done") { onDone() }
                }
            }
        }
    }
}

/// Puts a pending card's review up wherever the app is.
struct ExpertCardImportHost: ViewModifier {
    @ObservedObject var inbox: ExpertCardInbox

    func body(content: Content) -> some View {
        content.sheet(item: $inbox.pending) { pending in
            ExpertCardImportSheet(pending: pending) { inbox.pending = nil }
        }
    }
}
