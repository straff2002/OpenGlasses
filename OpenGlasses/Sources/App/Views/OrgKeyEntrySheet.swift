import SwiftUI

/// Plan CT 3a — "My company gave me a key or code", from the welcome page.
///
/// One field takes the short activation key (grouped in fours as it is typed) or a full licence
/// code, and the scanner beside it reads either, or an enrolment link. A key is checked locally and
/// looked up once before this sheet closes; what it resolves to is handed back and acted on only
/// after the sheet has gone, so the organisation's review sheet is never asked to present over it.
struct OrgKeyEntrySheet: View {
    enum Outcome: Equatable {
        /// A licence code, typed or resolved from an activation key.
        case licence(String)
        /// An enrolment link or profile address read by the scanner.
        case scanned(String)
    }

    let service: OrgEnrolmentService
    let finish: (Outcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?
    @State private var isLookingUp = false
    @State private var scanning = false
    @State private var scannedCode: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("K7Q3-X9PD-M2VA-8RTN", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .font(.system(.title3, design: .monospaced))
                        .onChange(of: text) { _, value in
                            let formatted = OrgFirstRun.formatKeyEntry(value)
                            if formatted != value { text = formatted }
                        }
                        .accessibilityLabel("Licence key")
                } header: {
                    Text("Licence key")
                } footer: {
                    Text("The activation key your company gave you, or the full licence code. Looking up an activation key needs the internet once.")
                }

                if let problem {
                    Section {
                        Label { Text(verbatim: problem) } icon: { Image(systemName: "exclamationmark.triangle") }
                    }
                }

                Section {
                    Button {
                        submit(text)
                    } label: {
                        if isLookingUp {
                            ProgressView("Looking up the key…")
                        } else {
                            Text("Continue")
                        }
                    }
                    .disabled(isLookingUp || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Scan a code instead") { scanning = true }
                        .disabled(isLookingUp)
                }
            }
            .navigationTitle("Your Company's Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $scanning, onDismiss: {
                if let code = scannedCode {
                    scannedCode = nil
                    handleScan(code)
                }
            }) {
                OrgCodeScannerView { code in scannedCode = code }
            }
        }
        .interactiveDismissDisabled(isLookingUp)
    }

    private func submit(_ entered: String) {
        isLookingUp = true
        problem = nil
        Task { @MainActor in
            let entry = await service.resolveEntry(entered)
            isLookingUp = false
            switch entry {
            case .licence(let code):
                finish(.licence(code))
                dismiss()
            case .refused(let message):
                problem = message
            }
        }
    }

    /// A scanned enrolment link or profile address goes to the link's path; anything else is a key
    /// or a code, put in the field and looked up as if typed.
    private func handleScan(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("openglasses:") || lowered.hasPrefix("https:") {
            finish(.scanned(trimmed))
            dismiss()
        } else {
            text = OrgFirstRun.formatKeyEntry(trimmed)
            submit(trimmed)
        }
    }
}

/// Where a first-run phone's organisation setup stands, under "Setting up for …" (Plan CT 3a).
/// Its own `@ObservedObject`, so the page follows the enrolment service's stage.
struct OrgSetupStatus: View {
    @ObservedObject var service: OrgEnrolmentService

    var body: some View {
        switch service.stage {
        case .fetching:
            HStack(spacing: 10) {
                ProgressView()
                Text("Fetching your organisation's settings…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            OGNotice(text: message, systemImage: "wifi.exclamationmark")
        case .offer, .reviewing, .modelKey:
            Text("Review what your organisation sets, then apply it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .applied:
            Text("Finishing…")
                .foregroundStyle(.secondary)
        case .idle:
            OGNotice(text: "Connect to the internet once to finish setting up this phone, then try again.",
                     systemImage: "wifi")
        }
    }
}
