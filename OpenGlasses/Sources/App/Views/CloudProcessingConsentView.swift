import SwiftUI

@MainActor
struct CloudProcessingConsentOverlay: View {
    @ObservedObject private var consent = CloudProcessingConsent.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        ZStack {
            if let prompt = consent.pending {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("Allow sharing with this service?").font(.title2.bold())
                            Text(prompt.terms.origin).font(.headline).textSelection(.enabled)
                            Text(prompt.terms.scope.title).font(.subheadline.bold())
                            Text(prompt.terms.scope.disclosure)
                            Text("The service handles this data under its own privacy and retention terms. Permission stays on until you withdraw it in Cloud AI Sharing. You can decline and use supported on-device processing instead.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Link("Privacy Policy", destination: PublicSite.privacy)
                            Button("Allow sending this data") { consent.respond(allow: true) }
                                .buttonStyle(.borderedProminent)
                            Button("Not now") { consent.respond(allow: false) }
                                .buttonStyle(.bordered)
                        }
                        .padding(24)
                        .frame(maxWidth: 540, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .padding()
                    }.frame(maxHeight: 680)
                }
                .accessibilityAddTraits(.isModal)
                .zIndex(1000)
            }
        }
        .allowsHitTesting(consent.pending != nil)
        .onAppear { consent.presenterAvailable = true }
        .onDisappear { consent.presenterAvailable = false; consent.cancelPending() }
        .onChange(of: phase) { _, value in
            if value != .active { consent.cancelPending() }
        }
    }
}

@MainActor
struct CloudProcessingSettingsView: View {
    @ObservedObject private var consent = CloudProcessingConsent.shared
    @State private var endpoint = ""
    @State private var scope = CloudProcessingScope.conversation
    @State private var notice: String?
    var body: some View {
        Form {
            Section {
                Text("You choose which services receive your content and what they may do with it. Saving an API key does not grant sharing permission. Supported on-device models and system voices do not need these permissions.")
                if let notice = consent.storageNotice { Text(notice).foregroundStyle(.red) }
            }
            Section("Allowed services") {
                if consent.approvals.isEmpty { Text("No services have permission yet.") }
                ForEach(consent.approvals) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.recipient).textSelection(.enabled)
                        if let scope = CloudProcessingScope.allCases.first(where: { $0.dataClass == record.dataClass }) {
                            Text(scope.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Withdraw permission", role: .destructive) { consent.withdraw(record) }
                    }
                }
            }
            Section {
                TextField("Service URL, for example https://api.example.com", text: $endpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Use", selection: $scope) {
                    ForEach(CloudProcessingScope.allCases) { Text($0.title).tag($0) }
                }
                Button("Review sharing permission") {
                    guard let url = URL(string: endpoint) else { notice = "Enter a valid service URL."; return }
                    Task {
                        do {
                            _ = try await consent.authorize(url: url, scope: scope, reviewAgain: true)
                            notice = "Permission saved."
                        } catch { notice = error.localizedDescription }
                    }
                }.disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let notice { Text(notice).font(.footnote) }
            } header: { Text("Review a service") } footer: {
                Text("Use the service address shown by your provider or in Where Your Requests Go. Only its scheme, host and port are saved; keys and URL paths are excluded. Review a withdrawn service here to allow it again.")
            }
        }.navigationTitle("Cloud AI Sharing")
    }
}
