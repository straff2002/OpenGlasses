import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// The phone side of the offline office ceremony. Public identity details can be copied to the
/// desktop; the administrator-signed binding is checked only after the owner reviews the office
/// shown there. This view cannot enable a Syncthing share or deliver content.
///
/// While it is open it has the app's one engine: the field connection is suspended for its own
/// connection test and resumed when it closes.
struct OfficePairingSheet: View {
    let field: OfficeFieldConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var manager = OrgProfileManager.shared
    @State private var phoneTransportID = ""
    @State private var phoneApplicationKey = ""
    @State private var officeID = ""
    @State private var officeTransportID = ""
    @State private var officeApplicationKey = ""
    @State private var signedBinding: Data?
    @State private var importing = false
    @State private var approving = false
    @State private var status: String?
    @State private var approvedGeneration: Int64?
    @State private var lanAddress = ""
    @State private var connecting = false
    @State private var connectionRunning = false
    @State private var connectionStatus: String?
    /// The typed address of a test that started, kept for the field connection once it connects.
    @State private var testedLanHint: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if phoneTransportID.isEmpty {
                        ProgressView("Preparing phone identity…")
                    } else {
                        LabeledContent("Transport ID", value: phoneTransportID)
                        LabeledContent("App public key", value: phoneApplicationKey)
                        if let id = manager.record?.enrolmentId {
                            LabeledContent("Enrolment ID", value: id)
                        }
                        Button("Copy public pairing details") {
                            UIPasteboard.general.string = """
                            enrolmentID: \(manager.record?.enrolmentId ?? "")
                            phoneTransportID: \(phoneTransportID)
                            phoneApplicationKey: \(phoneApplicationKey)
                            """
                        }
                    }
                } header: {
                    Text("This phone")
                } footer: {
                    Text("Share these public details with Avenkin Office. The phone's private keys stay here.")
                }

                Section {
                    TextField("Office ID", text: $officeID)
                        .textInputAutocapitalization(.never)
                    TextField("Office transport ID", text: $officeTransportID)
                        .textInputAutocapitalization(.never)
                    TextField("Office app public key", text: $officeApplicationKey)
                        .textInputAutocapitalization(.never)
                    Button(signedBinding == nil ? "Import signed office binding" : "Replace signed binding") {
                        importing = true
                    }
                    if signedBinding != nil { Label("Binding file loaded", systemImage: "doc.badge.checkmark") }
                } header: {
                    Text("Office to approve")
                } footer: {
                    Text("Compare these values with Avenkin Office on the office computer. The imported file must be signed by the administrator named in your vendor-verified organisation profile.")
                }

                Section {
                    Button(approving ? "Checking…" : "Verify and approve this office") {
                        Task { await approve() }
                    }
                    .disabled(approving || signedBinding == nil || phoneTransportID.isEmpty
                              || officeID.isEmpty || officeTransportID.isEmpty || officeApplicationKey.isEmpty)
                    if let generation = approvedGeneration {
                        Label("Office binding verified · generation \(generation)", systemImage: "checkmark.shield")
                    }
                    if let status { Text(verbatim: status).foregroundStyle(.secondary) }
                } footer: {
                    Text("Approval retains the signed identity binding. Job and manual delivery is not enabled by this step.")
                }

                Section {
                    TextField("Office LAN address · tcp://192.168.1.2:22000", text: $lanAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if connectionRunning {
                        Button("Stop office connection") {
                            Task { await stopConnection() }
                        }
                    } else {
                        Button(connecting ? "Starting…" : "Test office connection") {
                            Task { await startConnection() }
                        }
                        .disabled(connecting || lanAddress.isEmpty)
                    }
                    if let connectionStatus { Text(verbatim: connectionStatus).foregroundStyle(.secondary) }
                } header: {
                    Text("Local connection test")
                } footer: {
                    Text("Use the LAN address shown in Avenkin Office. The phone checks its saved approval again, pins the office certificate and opens no shared folders. Keep this screen open for the test.")
                }
            }
            .navigationTitle("Pair Avenkin Office")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            await field.suspend()
            await loadIdentity()
            await monitorConnection()
        }
        .onDisappear {
            Task {
                await OfficeTransportIdentity.shared.stop()
                field.resume()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await stopConnection() } }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .failure:
                status = "Couldn't open the binding file. Choose it again."
            case .success(let url):
                Task {
                    do {
                        let bytes = try await Task.detached {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            return try handle.read(upToCount: OfficePeerBinding.maximumEnvelopeBytes + 1) ?? Data()
                        }.value
                        guard bytes.count <= OfficePeerBinding.maximumEnvelopeBytes else {
                            status = "The binding file is too large."
                            signedBinding = nil
                            return
                        }
                        signedBinding = bytes
                        approvedGeneration = nil
                        status = nil
                    } catch {
                        signedBinding = nil
                        status = "Couldn't read the binding file. Choose it again."
                    }
                }
            }
        }
        .onChange(of: officeID) { _, _ in approvedGeneration = nil; status = nil }
        .onChange(of: officeTransportID) { _, _ in approvedGeneration = nil; status = nil }
        .onChange(of: officeApplicationKey) { _, _ in approvedGeneration = nil; status = nil }
    }

    private func loadIdentity() async {
        do {
            phoneTransportID = try await OfficeTransportIdentity.shared.deviceID()
            phoneApplicationKey = try await OfficePhoneIdentity.shared.publicKey().base64EncodedString()
        } catch {
            status = "Phone transport identity is unavailable in this build. Use an Avenkin transport-enabled build."
        }
    }

    private func approve() async {
        guard let signedBinding,
              let applicationKey = Data(base64Encoded: officeApplicationKey), applicationKey.count == 32 else {
            status = "Enter the office's complete public key and choose its signed binding."
            return
        }
        approving = true
        defer { approving = false }
        do {
            let reviewed = OfficePairingService.ReviewedOffice(
                officeID: officeID.trimmingCharacters(in: .whitespacesAndNewlines),
                transportID: officeTransportID.trimmingCharacters(in: .whitespacesAndNewlines),
                applicationPublicKey: applicationKey)
            let result = try await OfficePairingService().approve(signedBinding, reviewedOffice: reviewed)
            approvedGeneration = result.binding.payload.generation
            status = "The signed office identity matches this phone. Delivery is not enabled yet."
        } catch {
            approvedGeneration = nil
            status = explanation(for: error)
        }
    }

    private func startConnection() async {
        guard let hint = OfficeApprovedPeerStore.lanHint(lanAddress.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            connectionStatus = "Enter the office's address on its own network, like tcp://192.168.1.2:22000."
            return
        }
        connecting = true
        defer { connecting = false }
        do {
            // A test engine may still be running from an earlier try.
            await OfficeTransportIdentity.shared.stop()
            try await OfficePairingService().connectToApprovedOffice(lanHint: hint)
            testedLanHint = hint
            await refreshConnection()
            if !connectionRunning { connectionStatus = "The office connection did not start. Check the LAN address." }
        } catch {
            if error is OfficePairingService.Refusal || error is OfficePeerBinding.Refusal {
                connectionStatus = explanation(for: error)
            } else {
                connectionStatus = "Local connection refused: \(error.localizedDescription)"
            }
        }
    }

    private func stopConnection() async {
        await OfficeTransportIdentity.shared.stop()
        testedLanHint = nil
        connectionRunning = false
        connectionStatus = "Office connection stopped."
    }

    private func monitorConnection() async {
        while !Task.isCancelled {
            await refreshConnection()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refreshConnection() async {
        guard let snapshot = try? await OfficeTransportIdentity.shared.snapshot(),
              let data = snapshot.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["managedOffice"] as? Bool == true,
              fields["running"] as? Bool == true else {
            connectionRunning = false
            return
        }
        do {
            _ = try await OfficePairingService().currentApprovedPeer()
        } catch {
            await OfficeTransportIdentity.shared.stop()
            connectionRunning = false
            connectionStatus = explanation(for: error)
            return
        }
        connectionRunning = true
        if fields["connected"] as? Bool == true {
            // The address reached the office: the field connection uses it from now on.
            if let hint = testedLanHint {
                testedLanHint = nil
                try? await OfficePairingService().rememberLanHint(hint)
            }
            let route = fields["observedConnectionType"] as? String ?? "private LAN"
            connectionStatus = "Connected to approved office via \(route). No folders are shared."
        } else {
            connectionStatus = "Waiting for the approved office on the local network. No folders are shared."
        }
    }

    private func explanation(for error: Error) -> String {
        if let refusal = error as? OfficePairingService.Refusal {
            switch refusal {
            case .noDesktopEnrolment: return "Import your organisation's signed Avenkin Office setup file first."
            case .inactiveLease: return "This organisation's management period is not active. Ask for a renewed setup file."
            case .missingLicence: return "This phone has no matching active organisation licence."
            case .noApprovedOffice: return "Approve a signed office binding on this phone first."
            case .approvalSuperseded: return "This office approval was replaced. Import its newest signed binding."
            case .changedDuringApproval: return "The organisation setup changed while you were approving. Review it again."
            case .noOfficeAddress: return "Enter the office's address on its own network, like tcp://192.168.1.2:22000."
            }
        }
        if let refusal = error as? OfficePeerBinding.Refusal {
            switch refusal {
            case .wrongPeer, .wrongOrganizationOrProfile:
                return "The signed binding names a different office or phone. Compare the public IDs and request a new binding."
            case .badSignature, .untrustedProfile:
                return "The office binding does not have the administrator signature required by this organisation."
            case .profileExpired, .notCurrentlyValid:
                return "The office binding or organisation profile has expired. Ask for a renewed one."
            case .rollback:
                return "This binding is older than the office generation already approved on this phone."
            case .malformed, .invalidFields:
                return "The office binding file is invalid. Ask for a new one."
            }
        }
        return "The office binding could not be verified. Check the office details and try again."
    }
}
