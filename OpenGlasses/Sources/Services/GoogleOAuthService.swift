import AuthenticationServices
import Foundation
import UIKit

/// Network/persistence edge for the Google OAuth flow behind the Vertex-AI Gemini provider
/// (Plan AI). Protocol logic (PKCE, URLs, request bodies, expiry) is pure in `GoogleOAuth`;
/// this service runs the browser session, performs token exchange/refresh, and keeps
/// credentials in the keychain — mirroring `ClaudeOAuthService`, except the browser leg uses
/// `ASWebAuthenticationSession` because Google blocks paste-a-code flows.
@MainActor
final class GoogleOAuthService: NSObject, ObservableObject {
    static let shared = GoogleOAuthService()

    /// Whether a Google account is currently connected (credentials on file).
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastError: String?

    private static let keychainKey = "googleOAuthCredentials"
    /// The slot this account's refreshes share (Plan FG P1a).
    static let refreshKey = SingleFlightRefresher.Key(provider: "google")

    private let credentialStore: OAuthCredentialStore
    private let session: URLSession
    private let refresher: SingleFlightRefresher

    private var credentials: GoogleOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }
    private var activeSession: ASWebAuthenticationSession?

    /// `store`, `session` and `refresher` are seams for the tests (Plan FG P1a): the app uses the
    /// keychain item, the shared session and the shared refresher.
    init(store: OAuthCredentialStore? = nil, session: URLSession = .shared,
         refresher: SingleFlightRefresher = .shared) {
        self.credentialStore = store ?? .keychain(Self.keychainKey)
        self.session = session
        self.refresher = refresher
        super.init()
        if let data = self.credentialStore.load(),
           let stored = try? JSONDecoder().decode(GoogleOAuth.Credentials.self, from: data) {
            credentials = stored
            isConnected = true
        }
    }

    // MARK: - Sign-in flow (browser session)

    /// Run the full browser sign-in. Returns true on success; failures land in `lastError`.
    @discardableResult
    func signIn() async -> Bool {
        let clientID = Config.googleOAuthClientID
        guard let scheme = GoogleOAuth.callbackScheme(clientID: clientID) else {
            lastError = String(localized: "Enter your GCP iOS OAuth client ID first (ends in .apps.googleusercontent.com).")
            return false
        }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        guard let url = GoogleOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: state) else {
            lastError = String(localized: "Couldn't build the Google sign-in URL.")
            return false
        }
        do {
            let callback = try await runBrowserSession(url: url, callbackScheme: scheme)
            guard let parsed = GoogleOAuth.parseCallback(url: callback),
                  parsed.state == nil || parsed.state == state else {
                lastError = String(localized: "Google sign-in returned an invalid response.")
                return false
            }
            guard let request = GoogleOAuth.tokenExchangeRequest(
                clientID: clientID, code: parsed.code, verifier: verifier) else {
                lastError = String(localized: "Couldn't build the token request.")
                return false
            }
            let response = try await performTokenRequest(request)
            adoptSignIn(GoogleOAuth.Credentials(response: response))
            lastError = nil
            return true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            lastError = nil   // user closed the sheet — not an error worth surfacing
            return false
        } catch {
            lastError = String(localized: "Sign-in failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Disconnect the Google account and wipe stored tokens.
    func signOut() {
        // First, so a refresh still in flight cannot write the account back after it is gone.
        refresher.invalidate(Self.refreshKey)
        credentials = nil
        credentialStore.remove()
        lastError = nil
    }

    // MARK: - Token access

    /// The current access token, refreshed first if it's at/near expiry.
    /// Returns nil when no account is connected or no usable token is left after the refresh.
    func validAccessToken() async -> String? {
        guard let current = credentials else { return nil }
        guard current.needsRefresh() else { return current.accessToken }
        return await refreshedAccessToken(rejecting: nil)
    }

    /// A replacement for `rejectedToken`, which the model endpoint just refused with a 401
    /// (Plan FG P1a). Refreshes whatever the stored expiry says — unless another caller has
    /// already replaced that token, in which case the replacement is returned as it stands.
    /// Returns nil when no account is connected or the refresh did not produce a new token.
    func accessToken(afterRejecting rejectedToken: String) async -> String? {
        guard credentials != nil else { return nil }
        return await refreshedAccessToken(rejecting: rejectedToken)
    }

    // MARK: - Internals

    /// Refresh through the single-flight slot, then read what the settled state leaves usable.
    private func refreshedAccessToken(rejecting rejectedToken: String?) async -> String? {
        await refresher.refresh(
            Self.refreshKey,
            fetch: { [weak self] () async throws -> GoogleOAuth.Credentials? in
                guard let self else { return nil }
                return try await self.fetchRefreshedCredentials(rejecting: rejectedToken)
            },
            commit: { [weak self] outcome in self?.settleRefresh(outcome) })
        guard let current = credentials else { return nil }
        if let rejectedToken { return current.accessToken == rejectedToken ? nil : current.accessToken }
        // A refresh that could not reach the service keeps the credential; its token still serves
        // until it actually expires.
        return current.needsRefresh(leeway: 0) ? nil : current.accessToken
    }

    /// The token request, made only if it is still needed when the slot's turn comes: nil when
    /// there is nothing to refresh, or a refresh that landed first already did the job.
    private func fetchRefreshedCredentials(rejecting rejectedToken: String?) async throws -> GoogleOAuth.Credentials? {
        guard let current = credentials, let refreshToken = current.refreshToken else {
            return nil   // no refresh token — the stored credential cannot be renewed
        }
        let stillNeeded = rejectedToken.map { $0 == current.accessToken } ?? current.needsRefresh()
        guard stillNeeded else { return nil }
        let response = try await performTokenRequest(GoogleOAuth.refreshRequest(clientID: Config.googleOAuthClientID, refreshToken: refreshToken))
        return GoogleOAuth.Credentials(response: response, previousRefreshToken: refreshToken)
    }

    /// Commit a refresh's outcome. Runs only while the refresh still owns its slot.
    private func settleRefresh(_ outcome: Result<GoogleOAuth.Credentials?, Error>) {
        switch outcome {
        case .success(let refreshed?):
            store(refreshed)
            lastError = nil
        case .success(nil):
            break
        case .failure(let error):
            // A refresh failure's description can quote the token endpoint's response body.
            PrivacyLog.authFailed(.google, .tokenRefresh, OAuthTokenEndpointError.summary(of: error))
            let failure = OAuthRefreshFailure.classify(error)
            if failure == .credentialDead {
                credentials = nil
                credentialStore.remove()
            }
            lastError = failure.message(provider: "Google")
        }
    }

    /// Store a completed sign-in. Any refresh still running belongs to the account it replaces.
    private func adoptSignIn(_ newCredentials: GoogleOAuth.Credentials) {
        refresher.invalidate(Self.refreshKey)
        store(newCredentials)
    }

    private func runBrowserSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            activeSession = session
            session.start()
        }
    }

    private func store(_ newCredentials: GoogleOAuth.Credentials) {
        credentials = newCredentials
        if let data = try? JSONEncoder().encode(newCredentials) {
            credentialStore.save(data)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> GoogleOAuth.TokenResponse {
        // Linking an account is a credential leaving the device; local-only refuses it rather
        // than letting a new provider be attached while the mode is on.
        try MedicalEgressGuard.check(.googleOAuthToken)
        _ = try EndpointPolicy.require(url: request.url ?? URL(fileURLWithPath: "/"), for: .googleOAuthToken)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw OAuthTokenEndpointError(status: status, body: data)
        }
        return try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: data)
    }
}

extension GoogleOAuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            // Prefer the scene the user is actually looking at, then any key window, then any
            // window at all — an existing window always beats a fresh one as an anchor.
            if let anchor = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow {
                return anchor
            }
            if let anchor = scenes.lazy.compactMap(\.keyWindow).first { return anchor }
            if let anchor = scenes.lazy.flatMap(\.windows).first { return anchor }
            if let scene = scenes.first { return UIWindow(windowScene: scene) }
            // Unreachable: `start()` is only called from a user-initiated sign-in, which requires
            // a live window scene. `init(windowScene:)` is the only UIWindow initialiser that
            // survives iOS 26, so a scene-less process has no anchor to offer — and the empty
            // window this used to return could never have presented anything either.
            preconditionFailure("presentationAnchor requested with no connected UIWindowScene")
        }
    }
}
