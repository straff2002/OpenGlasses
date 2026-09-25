import SwiftUI
import CoreImage

/// Plan CT 3b — the row that opens what the Field Assist edition hides, and the banner while an
/// administrator session is open. Shown only on a phone whose profile names an edition.
struct OrgAdministratorSection: View {
    @ObservedObject var gate: AdminGate
    @ObservedObject var manager: OrgProfileManager
    @State private var unlocking = false
    @State private var showingCard = false
    @State private var confirmingStop = false
    @State private var cardError: String?

    var body: some View {
        if let policy = gate.policy {
            if gate.isAdministratorPhone {
                administratorPhoneSection
            } else if gate.isRestricted {
                OGSection(footer: restrictedFooter) {
                    Button {
                        unlocking = true
                    } label: {
                        OGRow("Administrator Settings", icon: "lock.fill")
                    }
                    .buttonStyle(.plain)
                }
                .sheet(isPresented: $unlocking) {
                    AdminUnlockSheet(gate: gate, policy: policy)
                }
            } else {
                OGSection {
                    OGNotice(text: "Administrator session. It ends when you leave the app, or after ten minutes without activity.",
                             systemImage: "person.badge.key")
                        .padding(12)
                    OGDivider()
                    Button {
                        gate.endSession()
                    } label: {
                        OGRow("End Administrator Session", icon: "lock", showsChevron: false)
                    }
                    .buttonStyle(.plain)
                }
                .onAppear { gate.noteActivity() }
            }
        }
    }

    private var organization: String { manager.profile?.organizationName ?? "your organisation" }

    private var restrictedFooter: LocalizedStringKey {
        if gate.keptCardIsStale {
            return "\(organization) has replaced its admin card. Scan the new one to make this an administrator phone again."
        }
        return "Opens the settings \(organization) keeps out of the technician's view. Its locks still apply to everyone."
    }

    /// Plan CT 3b: a supervisor's phone that kept the card. Never mistaken for a technician's.
    private var administratorPhoneSection: some View {
        OGSection(header: "Administrator Phone") {
            OGNotice(text: "This is an administrator phone for \(organization): it shows everything, and it can show the admin card for a technician's phone to scan. Its locks still apply.",
                     systemImage: "person.badge.key.fill")
                .padding(12)
            OGDivider()
            Button(action: showCard) {
                OGRow("Show Admin Card", icon: "qrcode")
            }
            .buttonStyle(.plain)
            OGDivider()
            Button(role: .destructive) {
                confirmingStop = true
            } label: {
                OGRow("Stop Being an Administrator Phone", icon: "xmark.circle", showsChevron: false)
            }
            .buttonStyle(.plain)
            if let cardError {
                OGDivider()
                OGStatusLabel(cardError, kind: .error)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .confirmationDialog("Stop being an administrator phone?", isPresented: $confirmingStop,
                            titleVisibility: .visible) {
            Button("Stop Being an Administrator Phone", role: .destructive) { gate.stopBeingAdministratorPhone() }
        } message: {
            Text("The card is deleted from this phone, and it shows the technician's view. Scanning the card again brings it back.")
        }
        .fullScreenCover(isPresented: $showingCard) {
            if let card = gate.cardToShow {
                AdminCardDisplay(card: card, organization: organization)
            }
        }
    }

    /// The card is the organisation's key to every technician's phone: a lost or unattended
    /// administrator phone must not hand it to whoever picks it up, so this fails closed.
    private func showCard() {
        cardError = nil
        OwnerGateAuth.authorize(reason: "Show the admin card") { authorization in
            Task { @MainActor in
                if authorization.isGranted {
                    showingCard = true
                } else {
                    cardError = "Couldn't verify it's you — the card stays hidden."
                }
            }
        }
    }
}

/// The admin card, full screen, for a technician's phone to scan. It hides itself after 30 seconds
/// and whenever the app leaves the screen.
struct AdminCardDisplay: View {
    let card: String
    let organization: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if visible, let image = Self.qrImage(card) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(24)
                        .accessibilityLabel(Text("\(organization)'s admin card"))
                    Text("Scan this from Administrator Settings on the technician's phone.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "eye.slash")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    Text("The card is hidden.")
                    Button("Show Again") { visible = true }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Admin Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: visible) {
                guard visible else { return }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                visible = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { visible = false }
            }
        }
    }

    private static func qrImage(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// Plan CT 3b — the unlock: scan the admin card, type the passcode, or — only when the profile
/// issued neither — the device owner's own Face ID or passcode, failing closed.
struct AdminUnlockSheet: View {
    @ObservedObject var gate: AdminGate
    let policy: AdminPolicy

    @Environment(\.dismiss) private var dismiss
    @State private var passcode = ""
    @State private var message: String?
    @State private var scanning = false
    @State private var scannedCode: String?
    @State private var rememberCard = false

    private var method: AdminCredentials.Method { policy.credentials.method }

    var body: some View {
        NavigationStack {
            List {
                if method == .card || method == .cardOrPasscode {
                    Section {
                        Button("Scan the Admin Card") { scanning = true }
                        Toggle("Make this an administrator phone", isOn: $rememberCard)
                    } footer: {
                        Text("Your administrator's card, printed or on another phone. It is read here, in the app — not with the Camera app. An administrator phone keeps the card, only on this phone, and shows everything until you stop it.")
                    }
                }

                if policy.credentials.passcode != nil {
                    Section {
                        SecureField("Administrator passcode", text: $passcode)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit(submitPasscode)
                        Button("Unlock", action: submitPasscode)
                            .disabled(passcode.isEmpty)
                    } header: {
                        Text("Passcode")
                    }
                }

                if method == .deviceOwner {
                    Section {
                        Button("Unlock with Face ID or Passcode", action: unlockAsDeviceOwner)
                    } footer: {
                        Text("Your organisation issued no admin card or passcode, so anyone who can unlock this phone can open administrator settings.")
                    }
                }

                if let message {
                    Section {
                        Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("A forgotten passcode or a lost card is replaced by your organisation, and this phone picks it up at its next renewal. There is no reset on the phone.")
                }
            }
            .navigationTitle("Administrator Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $scanning, onDismiss: {
                if let code = scannedCode {
                    scannedCode = nil
                    let attempt = gate.tryCard(code, remember: rememberCard)
                    if attempt == .notApplicable {
                        report("That isn't an admin card.")
                    } else {
                        settle(attempt)
                    }
                }
            }) {
                OrgCodeScannerView { code in scannedCode = code }
            }
        }
    }

    private func submitPasscode() {
        guard !passcode.isEmpty else { return }
        let attempt = gate.tryPasscode(passcode)
        passcode = ""
        settle(attempt)
    }

    private func unlockAsDeviceOwner() {
        OwnerGateAuth.authorize(reason: "Open administrator settings") { authorization in
            Task { @MainActor in
                if authorization.isGranted {
                    settle(gate.deviceOwnerPassed())
                } else {
                    report("Couldn't verify it's you.")
                }
            }
        }
    }

    private func settle(_ attempt: AdminGate.Attempt) {
        switch attempt {
        case .granted:
            dismiss()
        case .refused(let waitUntil):
            if let waitUntil {
                report("That's not right. Too many attempts — try again \(Self.when(waitUntil)).")
            } else {
                report("That's not right.")
            }
        case .waiting(let until):
            report("Too many attempts. Try again \(Self.when(until)).")
        case .notApplicable:
            report("This phone doesn't take that.")
        }
    }

    /// Shown, and spoken to VoiceOver, so a wait is never silent.
    private func report(_ text: String) {
        message = text
        SessionAnnouncer.say(text, interrupts: true)
    }

    private static func when(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
