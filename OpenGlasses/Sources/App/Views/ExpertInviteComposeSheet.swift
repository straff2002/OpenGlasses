import SwiftUI

/// Field Assist › Experts › Invite an Expert (Plan KW §4): ask someone who uses Avenkin for their
/// expert card. Nothing about the expert is typed but a name for your own list; the invite carries
/// your organisation's name, yours, and where they send the card back. It goes by your own share,
/// and the experts list shows it as invited until their card answers it or it runs out.
struct ExpertInviteComposeSheet: View {
    let experts: ExpertListStore
    var onSent: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage("expertInviteSenderName") private var senderName = ""
    @AppStorage("expertInviteReplyTo") private var replyTo = ""
    @State private var inviteeName = ""
    @State private var sharing: ShareItem?
    @State private var problem: String?

    private var organisation: String { ExpertHandoverService.organisation().name }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Their name, for your list", text: $inviteeName)
                        .textContentType(.name)
                } header: {
                    Text("Who you're inviting")
                }

                Section {
                    TextField("Your name", text: $senderName)
                        .textContentType(.name)
                    TextField("Your number or email", text: $replyTo)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Where they send their card")
                } footer: {
                    Text(organisation.isEmpty
                         ? "The invite says it's from you. It carries no rate, job or customer: it only opens the card form on their phone, and their card works for every company they help."
                         : "The invite says it's from \(organisation). It carries no rate, job or customer: it only opens the card form on their phone, and their card works for every company they help.")
                }

                Section {
                    Button("Send Invite…") { send() }
                        .disabled(senderName.trimmingCharacters(in: .whitespaces).isEmpty && organisation.isEmpty)
                } footer: {
                    Text("They need Avenkin, but not Field Assist. The invite runs out in \(ExpertInvite.validDays) days.")
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .ogFormStyle()
            .navigationTitle("Invite an Expert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $sharing) { item in
                ShareSheet(items: item.items, onComplete: item.onComplete)
            }
        }
    }

    /// The invite goes as a small file from the share sheet, written to the temporary folder and
    /// removed when the share ends. Only a completed share puts it on the list.
    private func send() {
        let invite = ExpertInvite(organisation: organisation, invitedBy: senderName, replyTo: replyTo, created: Date())
        if let why = invite.problem {
            problem = String(localized: "The invite can't be made: \(why).")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExpertInvite-\(UUID().uuidString)",
                                                                                    isDirectory: true)
        let url = folder.appendingPathComponent(ExpertInviteCodec.fileName(invite))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ExpertInviteCodec.fileData(invite).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            problem = String(localized: "The invite file couldn't be written. Try again.")
            return
        }
        problem = nil
        let name = inviteeName
        sharing = ShareItem(items: [url]) { completed in
            try? FileManager.default.removeItem(at: folder)
            guard completed else { return }
            experts.recordSentInvite(SentExpertInvite(invite: invite, inviteeName: name))
            onSent()
            dismiss()
        }
    }
}
