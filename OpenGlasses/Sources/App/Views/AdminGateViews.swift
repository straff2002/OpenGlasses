import SwiftUI

/// Plan CT 3b — the row that opens what the Field Assist edition hides, and the banner while an
/// administrator session is open. Shown only on a phone whose profile names an edition.
struct OrgAdministratorSection: View {
    @ObservedObject var gate: AdminGate
    @ObservedObject var manager: OrgProfileManager
    @State private var unlocking = false

    var body: some View {
        if let policy = gate.policy {
            if gate.isRestricted {
                OGSection(footer: "Opens the settings \(organization) keeps out of the technician's view. Its locks still apply to everyone.") {
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

    private var method: AdminCredentials.Method { policy.credentials.method }

    var body: some View {
        NavigationStack {
            List {
                if method == .card || method == .cardOrPasscode {
                    Section {
                        Button("Scan the Admin Card") { scanning = true }
                    } footer: {
                        Text("Your administrator's card, printed or on another phone. It is read here, in the app — not with the Camera app.")
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
                    let attempt = gate.tryCard(code)
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
