import SwiftUI

/// What a browser-based account sign-in service looks like to the UI (Plan BW P3). Both the
/// Claude and ChatGPT OAuth services conform, so the model editor renders one component for
/// either instead of hand-rolled per-provider copies.
@MainActor
protocol OAuthSignInService: ObservableObject {
    var isConnected: Bool { get }
    var lastError: String? { get }
    func beginSignIn() -> URL?
    @discardableResult
    func completeSignIn(pastedCode: String) async -> Bool
    func signOut()

    /// The redirect registered for this provider's OAuth client (Plan DD). A loopback redirect
    /// is one the app can answer itself while the sign-in sheet is up — that's the zero-paste
    /// path; anything else still ends with a code coming back by hand.
    var signInRedirect: OAuthRedirect? { get }
    /// The `state` minted by the most recent `beginSignIn()`, so a captured callback can be
    /// authenticated before its code is used.
    var pendingSignInState: String? { get }
    /// Complete a sign-in with a code the loopback listener captured (already state-validated).
    @discardableResult
    func completeSignIn(capturedCode: String) async -> Bool
}

extension OAuthSignInService {
    /// Providers that haven't declared a redirect get the paste path, as before.
    var signInRedirect: OAuthRedirect? { nil }
    var pendingSignInState: String? { nil }

    @discardableResult
    func completeSignIn(capturedCode: String) async -> Bool {
        await completeSignIn(pastedCode: capturedCode)
    }
}

extension ClaudeOAuthService: OAuthSignInService {
    /// This client's registered redirect is a provider-hosted page that displays the code, not a
    /// loopback URL — so there is nothing for a local listener to catch and the flow keeps its
    /// paste step. Derived from the constant so it follows if the redirect ever changes.
    var signInRedirect: OAuthRedirect? { OAuthRedirect(ClaudeOAuth.redirectURI) }
}

extension ChatGPTOAuthService: OAuthSignInService {
    /// A loopback redirect — the app answers it itself, so this flow is zero-paste.
    var signInRedirect: OAuthRedirect? { OAuthRedirect(ChatGPTOAuth.redirectURI) }
}

/// The onboarding flow's account sign-in section: same behaviour as `OAuthSignInRows`, shaped as
/// a grouped `Section` so it sits in onboarding's list pages like any other iOS setting.
/// Generalized from the original Claude-only onboarding section so ChatGPT reuses it (BW P4).
///
/// Sign-in happens in an in-app sheet (Plan DD P2): when the provider's redirect points back at
/// this device the code is captured straight off it and the user never pastes anything. The
/// paste field and the open-in-browser route stay as fallbacks for every other case.
struct OnboardingAccountSignInSection<Service: OAuthSignInService>: View {
    @ObservedObject var service: Service
    let signInLabel: String
    let caption: String
    let connectedCaption: String
    let pasteInstructions: String
    var onConnected: () -> Void = {}
    var onSignedOut: () -> Void = {}

    @Environment(\.appAccent) private var accent
    @StateObject private var flow = SignInSheetModel()
    @State private var code = ""
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44

    var body: some View {
        Section {
            if service.isConnected {
                connectedRow
            } else {
                signInRow
                pasteFallbackRows
                if let error = service.lastError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(OGTheme.errorLabel)
                }
            }
        } header: {
            Text("Account")
        } footer: {
            Text(service.isConnected ? connectedCaption : caption)
        }
    }

    private var connectedRow: some View {
        HStack(spacing: OGMetrics.rowSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(OGTheme.okLabel)
                .accessibilityHidden(true)
            Text("Account connected")
                .font(.body)
            Spacer(minLength: 8)
            Button("Sign out", role: .destructive) {
                service.signOut()
                flow.reset()
                code = ""
                onSignedOut()
            }
            .buttonStyle(.borderless)
        }
        .frame(minHeight: rowMinHeight)
    }

    private var signInRow: some View {
        Button {
            startSignIn()
        } label: {
            HStack(spacing: 8) {
                if flow.state.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                    Text(signInLabel)
                }
            }
        }
        .buttonStyle(.ogProminent)
        .disabled(flow.state.isBusy)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowBackground(Color.clear)
        .sheet(item: $flow.request, onDismiss: { flow.sheetDismissed() }) { request in
            SignInSheetView(url: request.url)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var pasteFallbackRows: some View {
        if flow.showsPasteFallback {
            if let reason = flow.fallbackReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Paste authorization code", text: $code)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.footnote.monospaced())
                .frame(minHeight: rowMinHeight)

            Button {
                submitPastedCode()
            } label: {
                HStack(spacing: 8) {
                    if flow.state.isBusy {
                        ProgressView().controlSize(.small)
                        Text("Connecting…")
                    } else {
                        Image(systemName: "link")
                        Text("Connect")
                    }
                }
                .font(.body)
                .foregroundStyle(OGTheme.tintedAccentLabel(accent))
                .frame(minHeight: rowMinHeight)
            }
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.state.isBusy)

            Button("Open in the browser instead") {
                flow.openExternally()
            }
            .font(.body)
            .foregroundStyle(OGTheme.tintedAccentLabel(accent))
            .frame(minHeight: rowMinHeight)

            Text(pasteInstructions)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startSignIn() {
        guard let url = service.beginSignIn() else { return }
        flow.present(url: url,
                     redirect: service.signInRedirect,
                     expectedState: service.pendingSignInState,
                     exchange: { await service.completeSignIn(capturedCode: $0) },
                     onConnected: { code = ""; onConnected() })
    }

    private func submitPastedCode() {
        flow.completePaste(code,
                           exchange: { await service.completeSignIn(pastedCode: $0) },
                           onConnected: { code = ""; onConnected() })
    }
}

/// Form-styled account sign-in rows: connected card with sign-out, or a sign-in button that
/// opens the login page in an in-app sheet and — when the provider's redirect can't be captured
/// locally — reveals a paste-the-code field. Generalized from the original Claude-only rows in
/// the model editor; shares the sheet + loopback capture with the onboarding section (Plan DD).
struct OAuthSignInRows<Service: OAuthSignInService>: View {
    @ObservedObject var service: Service
    let signInLabel: String
    let connectedLabel: String
    let connectedCaption: String
    let pasteInstructions: String
    /// Called when the connection state changes (sign-in completed / signed out), so the host
    /// can invalidate anything derived from the credential (e.g. a fetched model list).
    var onChange: () -> Void = {}

    @Environment(\.appAccent) private var accent
    @StateObject private var flow = SignInSheetModel()
    @State private var code = ""
    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 44

    var body: some View {
        if service.isConnected {
            connectedRow
        } else {
            signInRow

            if flow.showsPasteFallback {
                pasteFallbackRows
            }

            if let error = service.lastError {
                OGStatusLabel(error, kind: .error)
            }
        }
    }

    private var connectedRow: some View {
        HStack(spacing: OGMetrics.rowSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(OGTheme.okLabel)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connectedLabel)
                    .font(.body)
                Text(connectedCaption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button("Sign out", role: .destructive) {
                service.signOut()
                flow.reset()
                code = ""
                onChange()
            }
            .buttonStyle(.borderless)
        }
        .frame(minHeight: rowMinHeight)
    }

    private var signInRow: some View {
        Button {
            startSignIn()
        } label: {
            HStack(spacing: 8) {
                if flow.state.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                } else {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .accessibilityHidden(true)
                    Text(signInLabel)
                }
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled(flow.state.isBusy)
        .accessibilityLabel(flow.state.isBusy ? "Connecting" : signInLabel)
        .sheet(item: $flow.request, onDismiss: { flow.sheetDismissed() }) { request in
            SignInSheetView(url: request.url)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var pasteFallbackRows: some View {
        if let reason = flow.fallbackReason {
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField("Paste authorization code", text: $code)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.footnote.monospaced())
            .frame(minHeight: rowMinHeight)

        Button {
            submitPastedCode()
        } label: {
            HStack(spacing: 8) {
                if flow.state.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                } else {
                    Image(systemName: "link")
                        .accessibilityHidden(true)
                    Text("Connect")
                }
            }
            .frame(minHeight: rowMinHeight)
        }
        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.state.isBusy)

        Button("Open in the browser instead") {
            flow.openExternally()
        }
        .font(.body)
        .foregroundStyle(OGTheme.tintedAccentLabel(accent))
        .frame(minHeight: rowMinHeight)

        Text(pasteInstructions)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startSignIn() {
        guard let url = service.beginSignIn() else { return }
        flow.present(url: url,
                     redirect: service.signInRedirect,
                     expectedState: service.pendingSignInState,
                     exchange: { await service.completeSignIn(capturedCode: $0) },
                     onConnected: { code = ""; onChange() })
    }

    private func submitPastedCode() {
        flow.completePaste(code,
                           exchange: { await service.completeSignIn(pastedCode: $0) },
                           onConnected: { code = ""; onChange() })
    }
}
