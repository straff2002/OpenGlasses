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

    private var credentials: GoogleOAuth.Credentials? {
        didSet { isConnected = credentials != nil }
    }
    private var activeSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        if let data = KeychainService.data(for: Self.keychainKey),
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
            lastError = "Enter your GCP iOS OAuth client ID first (ends in .apps.googleusercontent.com)."
            return false
        }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        guard let url = GoogleOAuth.authorizeURL(clientID: clientID, verifier: verifier, state: state) else {
            lastError = "Couldn't build the Google sign-in URL."
            return false
        }
        do {
            let callback = try await runBrowserSession(url: url, callbackScheme: scheme)
            guard let parsed = GoogleOAuth.parseCallback(url: callback),
                  parsed.state == nil || parsed.state == state else {
                lastError = "Google sign-in returned an invalid response."
                return false
            }
            guard let request = GoogleOAuth.tokenExchangeRequest(
                clientID: clientID, code: parsed.code, verifier: verifier) else {
                lastError = "Couldn't build the token request."
                return false
            }
            let response = try await performTokenRequest(request)
            store(GoogleOAuth.Credentials(response: response))
            lastError = nil
            return true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            lastError = nil   // user closed the sheet — not an error worth surfacing
            return false
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Disconnect the Google account and wipe stored tokens.
    func signOut() {
        credentials = nil
        _ = KeychainService.delete(Self.keychainKey)
        lastError = nil
    }

    // MARK: - Token access

    /// The current access token, refreshed first if it's at/near expiry.
    /// Returns nil when no account is connected or the refresh fails.
    func validAccessToken() async -> String? {
        guard var current = credentials else { return nil }
        guard current.needsRefresh() else { return current.accessToken }
        guard let refreshToken = current.refreshToken else { return nil }
        do {
            let response = try await performTokenRequest(
                GoogleOAuth.refreshRequest(clientID: Config.googleOAuthClientID, refreshToken: refreshToken))
            current = GoogleOAuth.Credentials(response: response, previousRefreshToken: refreshToken)
            store(current)
            return current.accessToken
        } catch {
            NSLog("[GoogleOAuth] Token refresh failed: %@", error.localizedDescription)
            lastError = "Google sign-in expired — please sign in again."
            return nil
        }
    }

    // MARK: - Internals

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
            _ = KeychainService.setData(data, for: Self.keychainKey)
        }
    }

    private func performTokenRequest(_ request: URLRequest) async throws -> GoogleOAuth.TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GoogleOAuth", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Token endpoint returned HTTP \(status)"
            ])
        }
        return try JSONDecoder().decode(GoogleOAuth.TokenResponse.self, from: data)
    }
}

extension GoogleOAuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
