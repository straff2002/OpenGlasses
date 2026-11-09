import SwiftUI
import CoreImage
import UIKit

/// The expert's card (Plan KM §7, P2): filled in once, shared as a file or a QR code with every
/// organisation the expert works for. The card is the expert's; each organisation adds its own
/// kind, hours and rate on its own list, so there is no field for them here.
///
/// Opened from an invite (Plan KW §4), it says who asked above the form, and Send Card sends the
/// card back carrying the invite's id, so the inviter's list matches it.
struct ExpertCardView: View {
    let cards: ExpertCardStore
    /// The invite this card answers, when it was opened from one.
    var answering: ExpertInvite? = nil
    /// The card was saved or deleted: Assisting's presence follows it.
    var onChange: () -> Void = {}
    /// The card's share to the inviter completed.
    var onAnswered: () -> Void = {}

    @State private var name = ""
    @State private var phone = ""
    @State private var faceTime = ""
    @State private var channel: EscalationContact.HandoverChannel?
    @State private var specialties = ""
    @State private var licences = ""
    @State private var cardId: String?
    @State private var problem: String?
    @State private var saved: ExpertCard?
    @State private var sharing: ShareItem?
    @State private var showingCode = false
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            if let answering {
                Section {
                    Text("\(answering.senderName) asked you to be one of their experts. Fill in your card once; it works for every company you help.")
                    if let replyTo = answering.replyTo {
                        LabeledContent("Send it to", value: answering.invitedBy.isEmpty ? replyTo : "\(answering.invitedBy), \(replyTo)")
                    }
                } footer: {
                    Text("The invite unlocks nothing else in the app, and your card carries no rate.")
                }
            }

            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                TextField("FaceTime (email or number)", text: $faceTime)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Send jobs by", selection: $channel) {
                    Text("Their choice").tag(EscalationContact.HandoverChannel?.none)
                    Text("Messages").tag(EscalationContact.HandoverChannel?.some(.messages))
                    Text("WhatsApp").tag(EscalationContact.HandoverChannel?.some(.whatsApp))
                    Text("Email").tag(EscalationContact.HandoverChannel?.some(.email))
                    Text("AirDrop").tag(EscalationContact.HandoverChannel?.some(.airDrop))
                }
            } header: {
                Text("How to reach you")
            }

            Section {
                TextField("Specialties, separated by commas", text: $specialties, axis: .vertical)
                    .lineLimit(1...4)
                TextField("Licensed for, one per line", text: $licences, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("What you know")
            } footer: {
                Text("For example \u{201C}furnace, heat pump, refrigeration\u{201D}, and the trades and places you're licensed for.")
            }

            Section {
                Button("Save Card") { save() }
                if let saved, let answering {
                    Button("Send Card to \(answering.senderName)…") { share(saved, answering: answering.inviteId) }
                    Button("Show Card Code") { showingCode = true }
                        .disabled(ExpertCardCodec.codeText(saved) == nil)
                } else if let saved {
                    Button("Share Card File…") { share(saved) }
                    Button("Show Card Code") { showingCode = true }
                        .disabled(ExpertCardCodec.codeText(saved) == nil)
                    if ExpertCardCodec.codeText(saved) == nil {
                        Text("This card is too long for a code. Share the file instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("An organisation adds you from the file or the code, and sets its own hours and rate. Your replies carry this card, so they match you exactly.")
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if saved != nil {
                Section {
                    Button("Delete Card", role: .destructive) { confirmingDelete = true }
                        .confirmationDialog("Delete your card?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                cards.remove()
                                load()
                                onChange()
                            }
                        } message: {
                            Text("Organisations that already added you keep their entry. A new card has a new id, so they'd need it again.")
                        }
                }
            }
        }
        .ogFormStyle()
        .navigationTitle("Expert Card")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .sheet(item: $sharing) { item in
            ShareSheet(items: item.items, onComplete: item.onComplete)
        }
        .sheet(isPresented: $showingCode) {
            if let saved, let text = ExpertCardCodec.codeText(saved) {
                ExpertCardCodeView(name: saved.name, text: text)
            }
        }
    }

    private func load() {
        let card = cards.card
        saved = card
        cardId = card?.cardId
        name = card?.name ?? ""
        phone = card?.phone ?? ""
        faceTime = card?.faceTimeHandle ?? ""
        channel = card?.handoverChannel
        specialties = card?.specialties.joined(separator: ", ") ?? ""
        licences = card?.licences.joined(separator: "\n") ?? ""
    }

    private func save() {
        let card = ExpertCard(cardId: cardId ?? ExpertCard.newId(), name: name, phone: phone, faceTimeHandle: faceTime,
                              handoverChannel: channel, specialties: ExpertSpecialty.parse(specialties),
                              licences: [licences])
        if let why = cards.save(card) {
            problem = String(localized: "The card can't be saved: \(why).")
        } else {
            problem = nil
            load()
            onChange()
        }
    }

    /// The card goes as a small file from the share sheet; the file is written to the temporary
    /// folder and removed when the share ends.
    private func share(_ card: ExpertCard, answering inviteId: String? = nil) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExpertCard-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(ExpertCardCodec.fileName(card))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ExpertInviteCodec.cardFileData(card, answering: inviteId)
                .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            problem = String(localized: "The card file couldn't be written. Try again.")
            return
        }
        sharing = ShareItem(items: [url]) { completed in
            try? FileManager.default.removeItem(at: folder)
            if completed, inviteId != nil { onAnswered() }
        }
    }
}

/// The card as a QR code, for an organisation to scan in Settings › Field Assist › Experts.
struct ExpertCardCodeView: View {
    let name: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = Self.qrImage(text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 320)
                        .padding()
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel(Text("Expert card code for \(name)"))
                }
                Text("Scan this in Avenkin under Settings → Field Assist → Experts → Scan a Card's Code.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding()
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    static func qrImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The card editor wired to Assisting, for screens outside it (Things to Try, Plan KW §5) that may
/// not name `AssistingService`: saving or deleting the card moves Assisting's presence.
struct ExpertCardEditor: View {
    private let service = AssistingService.shared

    var body: some View {
        ExpertCardView(cards: service.cards, onChange: { service.refreshPresence() })
    }
}
