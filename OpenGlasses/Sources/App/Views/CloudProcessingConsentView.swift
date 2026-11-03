import SwiftUI
import UIKit

/// Stays in the app's view tree, where the biometric lock can remove it, and shows the question in
/// a window above everything, because a sheet or a cover would otherwise hide it.
@MainActor
struct CloudProcessingConsentOverlay: View {
    @ObservedObject private var consent = CloudProcessingConsent.shared
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                // A unit-test run hosts the app, and nobody is there to answer.
                guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                consent.presenterAvailable = true
                CloudSharingReview.shared.startObserving()
                CloudSharingReview.shared.run()
                CloudProcessingConsentWindow.shared.update(showing: consent.pending != nil)
            }
            .onDisappear {
                consent.presenterAvailable = false
                consent.cancelPending()
                CloudProcessingConsentWindow.shared.update(showing: false)
            }
            .onChange(of: consent.pending?.id) { _, id in
                CloudProcessingConsentWindow.shared.update(showing: id != nil)
            }
            .onChange(of: phase) { _, value in
                if value == .active { CloudSharingReview.shared.run() } else { consent.cancelPending() }
            }
    }
}

@MainActor
final class CloudProcessingConsentWindow {
    static let shared = CloudProcessingConsentWindow()
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func update(showing: Bool) {
        if showing { show() } else { hide() }
    }

    private func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: CloudProcessingConsentCard())
        host.view.backgroundColor = .clear
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    private func hide() {
        guard let window else { return }
        window.isHidden = true
        self.window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }
}

@MainActor
struct CloudProcessingConsentCard: View {
    @ObservedObject private var consent = CloudProcessingConsent.shared
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            if let prompt = consent.pending {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(title(prompt)).font(.title2.bold())
                        Text(prompt.terms.origin).font(.headline).textSelection(.enabled)
                        ForEach(prompt.scopes) { scope in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scope.title).font(.subheadline.bold())
                                Text(scope.disclosure)
                            }
                        }
                        Text("The service handles this data under its own privacy and retention terms. Permission stays on until you withdraw it in Cloud AI Sharing, and it lets hands-free requests reach this service. If you choose Not now, anything you've saved stays saved and nothing is sent. You can use supported on-device processing instead.")
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
                }
                .frame(maxHeight: 680)
                .accessibilityAddTraits(.isModal)
            }
        }
    }

    private func title(_ prompt: CloudProcessingConsent.Prompt) -> String {
        guard let name = prompt.serviceName else { return String(localized: "Allow sharing with this service?") }
        return String(localized: "Allow sharing with \(name)?")
    }
}

/// The services this phone is set up to use, each with what it's for and a yes or no. There is no
/// address to type: everything set up is already listed, and anything else asks when it's used.
@MainActor
struct CloudProcessingSettingsView: View {
    @ObservedObject private var consent = CloudProcessingConsent.shared
    @State private var services: [CloudService] = []
    @State private var notice: String?

    /// Approvals for services not in the list above: a gateway, or a model since removed.
    private var otherApprovals: [ConsentRecord] {
        consent.approvals.filter { record in !services.contains { $0.origin == record.recipient } }
    }

    var body: some View {
        Form {
            Section {
                Text("Avenkin asks before your content goes to a cloud service: when you add a key or choose a model, or the first time a service is used. Allowing a service then lets hands-free requests reach it. Supported on-device models and system voices don't need permission.")
                if let notice = consent.storageNotice { Text(notice).foregroundStyle(.red) }
                if let notice { Text(notice).font(.footnote) }
            }
            Section("Your services") {
                if services.isEmpty { Text("No cloud services are set up.") }
                ForEach(services) { service in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name).font(.headline)
                            Text(service.origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ForEach(service.scopes) { scope in
                            row(service, scope: scope)
                        }
                    }
                }
            }
            if !otherApprovals.isEmpty {
                Section("Other allowed services") {
                    ForEach(otherApprovals) { record in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(record.recipient).textSelection(.enabled)
                            if let scope = CloudProcessingScope.allCases.first(where: { $0.dataClass == record.dataClass }) {
                                Text(scope.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Withdraw permission", role: .destructive) { consent.withdraw(record) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Cloud AI Sharing")
        .onAppear { services = CloudServiceFactsProvider.current() }
    }

    private func row(_ service: CloudService, scope: CloudProcessingScope) -> some View {
        // `revision` is what changes when an answer is given, so the row redraws with it.
        let record = consent.revision >= 0 ? consent.approval(service, scope: scope) : nil
        return HStack {
            Text(scope.title).font(.subheadline)
            Spacer()
            if let record {
                Button("Withdraw", role: .destructive) { consent.withdraw(record) }
                    .buttonStyle(.borderless)
            } else {
                Button("Allow") {
                    Task {
                        do { try await consent.allow(service, scope: scope); notice = nil }
                        catch { notice = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(service.name), \(scope.title)")
    }
}
