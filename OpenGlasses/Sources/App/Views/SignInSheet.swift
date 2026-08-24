import SafariServices
import SwiftUI

/// One in-app sign-in sheet presentation (Plan DD P2). Identifiable so `.sheet(item:)` restarts
/// cleanly when a second attempt mints a fresh authorize URL.
struct SignInSheetRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// The provider's login page, shown inside the app instead of handing the user to the browser.
/// Staying foreground-active is what makes the loopback capture possible at all — a backgrounded
/// app gets suspended and nothing is left listening when the redirect fires.
struct SignInSheetView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Drives one account sign-in: presents the login sheet, runs the loopback listener for exactly
/// as long as the sheet is on screen, and moves a `SignInFlowState` through the attempt.
///
/// Both paths land here — the seamless one (listener catches the redirect) and the paste
/// fallback — so the UI reads a single state whichever way the code came back. Anything that
/// stops the seamless path (no loopback redirect registered, port busy, listener failure,
/// timeout, sheet dismissed) turns the paste fallback on rather than dead-ending.
@MainActor
final class SignInSheetModel: ObservableObject {
    @Published private(set) var state: SignInFlowState = .idle
    /// Non-nil while the login sheet should be on screen.
    @Published var request: SignInSheetRequest?
    /// Whether to offer the paste field and the open-in-browser route.
    @Published private(set) var showsPasteFallback = false

    /// The authorize URL of the current attempt, kept so the user can reopen it externally.
    private(set) var authURL: URL?

    private var server: LoopbackCallbackServer?
    private var captureTask: Task<Void, Never>?
    private var exchangeTask: Task<Void, Never>?

    // MARK: - Presenting

    /// Show the provider's login page and, when its registered redirect points back at this
    /// device, start listening for the callback.
    func present(url: URL,
                 redirect: OAuthRedirect?,
                 expectedState: String?,
                 exchange: @escaping (String) async -> Bool,
                 onConnected: @escaping () -> Void) {
        stopListening()
        authURL = url
        showsPasteFallback = false
        state = .idle

        // A callback can only be captured when the redirect comes back to us *and* there is a
        // state to authenticate it against.
        let canListen = redirect?.isLoopback == true && expectedState != nil
        state.apply(.present(listening: canListen))
        request = SignInSheetRequest(url: url)

        guard canListen, let redirect, let expectedState else {
            // Provider-hosted callback page: the in-app sheet is still the nicer surface, but
            // the code comes back by paste.
            showsPasteFallback = true
            return
        }

        let server = LoopbackCallbackServer()
        self.server = server
        captureTask = Task { [weak self] in
            let outcome = await server.capture(expectedState: expectedState,
                                               port: redirect.port,
                                               callbackPath: redirect.path)
            guard let self, !Task.isCancelled else { return }
            self.received(outcome, exchange: exchange, onConnected: onConnected)
        }
    }

    /// The sheet went away — for any reason. Stop listening immediately; if nothing had come
    /// back yet, leave the paste route on screen.
    func sheetDismissed() {
        stopListening()
        if state.apply(.cancel) {
            showsPasteFallback = true
        }
    }

    /// Hand the login page to the system browser instead (password-manager autofill, say). The
    /// listener stops with the sheet, so this path always ends in a paste.
    func openExternally() {
        guard let url = authURL else { return }
        stopListening()
        request = nil
        showsPasteFallback = true
        UIApplication.shared.open(url)
    }

    // MARK: - Completing

    /// Finish with a code the user pasted, through the same flow state as the seamless path.
    func completePaste(_ pasted: String,
                       exchange: @escaping (String) async -> Bool,
                       onConnected: @escaping () -> Void) {
        guard state.apply(.beginExchange) else { return }
        runExchange(with: pasted, exchange: exchange, onConnected: onConnected)
    }

    /// Reset after a sign-out so a later attempt starts clean.
    func reset() {
        stopListening()
        exchangeTask?.cancel()
        exchangeTask = nil
        authURL = nil
        showsPasteFallback = false
        state.apply(.reset)
    }

    // MARK: - Internals

    private func received(_ outcome: LoopbackCallbackServer.Outcome,
                          exchange: @escaping (String) async -> Bool,
                          onConnected: @escaping () -> Void) {
        captureTask = nil
        server = nil
        switch outcome {
        case .captured(let code, _):
            state.apply(.capture)
            guard state.apply(.beginExchange) else { return }
            request = nil            // we have what we came for — take the sheet away
            runExchange(with: code, exchange: exchange, onConnected: onConnected)

        case .portUnavailable, .listenerFailed, .timedOut:
            // The redirect will land on a page that can't load; the code is still in the address
            // bar, so surface the paste route and leave the sheet up.
            showsPasteFallback = true

        case .cancelled:
            break                    // `sheetDismissed` owns that transition
        }
    }

    private func runExchange(with code: String,
                             exchange: @escaping (String) async -> Bool,
                             onConnected: @escaping () -> Void) {
        exchangeTask?.cancel()
        exchangeTask = Task { [weak self] in
            let ok = await exchange(code)
            guard let self else { return }
            self.exchangeTask = nil
            if ok {
                self.state.apply(.succeed)
                self.request = nil
                self.showsPasteFallback = false
                onConnected()
            } else {
                // The service publishes the specific reason; keep the fallback available.
                self.state.apply(.fail(reason: ""))
                self.showsPasteFallback = true
            }
        }
    }

    private func stopListening() {
        captureTask?.cancel()
        captureTask = nil
        server?.stop()
        server = nil
    }
}
