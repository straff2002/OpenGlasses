import Foundation
import CryptoKit

/// Shared OAuth building blocks used by both account sign-in flows (Claude and ChatGPT):
/// PKCE derivation (RFC 7636) and pasted-authorization-input parsing. Pure — no I/O.
enum PKCE {

    /// Base64url (no padding) — the encoding PKCE uses for both verifier and challenge.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Derive a code verifier from random bytes (injectable so tests are deterministic).
    static func verifier(from randomBytes: Data) -> String {
        base64URL(randomBytes)
    }

    /// Generate a fresh random verifier (32 random bytes → 43-char base64url string).
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return verifier(from: Data(bytes))
    }

    /// S256 code challenge for a verifier (RFC 7636).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

/// The redirect a provider registered for its public OAuth client, as a value (Plan DD P1).
///
/// This is what decides whether a sign-in can be zero-paste: a loopback redirect points back at
/// the device, so the app can answer it itself while the sign-in sheet is up. Anything else — a
/// provider-hosted page that displays a code, say — still ends with the user pasting. Derived
/// from the registered redirect constant rather than hard-coded per provider, so a provider that
/// changes its redirect changes paths here too.
struct OAuthRedirect: Equatable {
    let host: String
    let port: UInt16
    let path: String

    /// True when the redirect resolves to this device — the only case a local listener can serve.
    var isLoopback: Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    init?(_ uriString: String) {
        guard let components = URLComponents(string: uriString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        self.host = host.lowercased()
        self.path = components.path.isEmpty ? "/" : components.path
        self.port = components.port.flatMap(UInt16.init(exactly:)) ?? (scheme == "https" ? 443 : 80)
    }
}

/// Parses whatever the user pastes back from a browser sign-in: `code#state`, a bare code, or a
/// full callback URL (including one copied out of the address bar when a localhost redirect
/// couldn't connect). Shared by both sign-in flows.
enum OAuthCodeInput {
    static func parse(_ input: String) -> (code: String, state: String?)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Full callback URL pasted: pull code/state from the query.
        if text.hasPrefix("http"), let components = URLComponents(string: text) {
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value
            if let code, !code.isEmpty { return (code, state) }
            if let fragment = components.fragment { text = fragment } else { return nil }
        }
        let parts = text.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { return nil }
        return (code, parts.count > 1 ? parts[1] : nil)
    }
}
