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

/// Dark full-screen-styled account sign-in section for the onboarding flow: same behaviour as
/// `OAuthSignInRows`, restyled for the black onboarding pages. Generalized from the original
/// Claude-only onboarding section so ChatGPT reuses it (BW P4).
///
/// Sign-in happens in an in-app sheet (Plan DD P2): when the provider's redirect points back at
/// this device the code is captured straight off it and the user never pastes anything. The
/// paste field and the open-in-browser route stay as fallbacks for every other case.
struct DarkAccountSignInSection<Service: OAuthSignInService>: View {
    @ObservedObject var service: Service
    let signInLabel: String
    let caption: String
    let connectedCaption: String
    let pasteInstructions: String
    /// Show the "or paste an API key" divider under the sign-in button (providers that also
    /// accept a key; ChatGPT has no key so it hides it).
    var showKeyDivider: Bool = false
    var onConnected: () -> Void = {}
    var onSignedOut: () -> Void = {}

    @StateObject private var flow = SignInSheetModel()
    @State private var code = ""

    var body: some View {
        if service.isConnected {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Account connected")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Text(connectedCaption)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button("Sign out") {
                    service.signOut()
                    flow.reset()
                    code = ""
                    onSignedOut()
                }
                .font(.caption)
                .foregroundStyle(.red.opacity(0.8))
            }
            .padding(14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.green.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 28)
        } else {
            VStack(spacing: 10) {
                Button {
                    startSignIn()
                } label: {
                    HStack(spacing: 8) {
                        if flow.state.isBusy {
                            ProgressView().scaleEffect(0.8).tint(.white)
                            Text("Connecting…")
                        } else {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text(signInLabel)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(flow.state.isBusy)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                if flow.showsPasteFallback {
                    if let reason = flow.fallbackReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }

                    TextField("Paste authorization code", text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    Button {
                        submitPastedCode()
                    } label: {
                        HStack(spacing: 6) {
                            if flow.state.isBusy {
                                ProgressView().scaleEffect(0.8)
                                Text("Connecting…")
                            } else {
                                Image(systemName: "link")
                                Text("Connect")
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.state.isBusy)

                    Button("Open in the browser instead") {
                        flow.openExternally()
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))

                    Text(pasteInstructions)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }

                if let error = service.lastError {
                    Label(error, systemImage: "xmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.8))
                }

                if showKeyDivider {
                    HStack(spacing: 12) {
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                        Text("or paste an API key")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize()
                        Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 28)
            .sheet(item: $flow.request, onDismiss: { flow.sheetDismissed() }) { request in
                SignInSheetView(url: request.url)
                    .ignoresSafeArea()
            }
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

    @StateObject private var flow = SignInSheetModel()
    @State private var code = ""

    var body: some View {
        if service.isConnected {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectedLabel)
                    Text(connectedCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign out", role: .destructive) {
                    service.signOut()
                    flow.reset()
                    code = ""
                    onChange()
                }
                .buttonStyle(.borderless)
            }
        } else {
            Button {
                startSignIn()
            } label: {
                if flow.state.isBusy {
                    HStack {
                        ProgressView().scaleEffect(0.8)
                        Text("Connecting…")
                    }
                } else {
                    Label(signInLabel, systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .disabled(flow.state.isBusy)
            .sheet(item: $flow.request, onDismiss: { flow.sheetDismissed() }) { request in
                SignInSheetView(url: request.url)
                    .ignoresSafeArea()
            }

            if flow.showsPasteFallback {
                if let reason = flow.fallbackReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Paste authorization code", text: $code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.footnote.monospaced())

                Button {
                    submitPastedCode()
                } label: {
                    HStack {
                        if flow.state.isBusy {
                            ProgressView().scaleEffect(0.8)
                            Text("Connecting…")
                        } else {
                            Image(systemName: "link")
                            Text("Connect")
                        }
                    }
                }
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || flow.state.isBusy)

                Button("Open in the browser instead") {
                    flow.openExternally()
                }
                .font(.caption)

                Text(pasteInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = service.lastError {
                Label(error, systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
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
