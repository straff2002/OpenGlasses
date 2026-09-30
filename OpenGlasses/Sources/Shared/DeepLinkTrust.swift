import Foundation

/// The app's own URL schemes (Plan FY P3.1, decision D3).
///
/// Both `openglasses://` and `avenkin://` are registered, and every handler asks this one helper
/// whether a link is the app's, so no route can accept one and refuse the other. Case-insensitive,
/// as URL schemes are. `openglasses://` is never retired: links already printed, scanned and saved
/// keep working for good.
///
/// Compiled into the app and the widget extension with `DeepLinkTrust`.
enum DeepLinkScheme {
    /// The scheme links are *generated* with. Stays `openglasses` until the build that accepts
    /// `avenkin://` is what users have (P3.3, a later release), so a link made today still opens
    /// on a phone that has not updated.
    static let generated = "openglasses"

    /// Every scheme the app answers to.
    static let accepted: Set<String> = ["openglasses", "avenkin"]

    static func isApp(_ url: URL) -> Bool { isApp(scheme: url.scheme) }

    static func isApp(scheme: String?) -> Bool {
        guard let scheme else { return false }
        return accepted.contains(scheme.lowercased())
    }
}

/// Caller authentication for the app's URL schemes (`DeepLinkScheme`).
///
/// A custom URL scheme is an **unauthenticated entry point**: any app on the device can call
/// `openURL("openglasses://action/photo")` and iOS will deliver it with no prompt and no usable
/// record of who sent it. Several of the app's deep links act on the world — they capture a frame
/// from the glasses camera and send it to an LLM, enable the microphone, or run a user-configured
/// quick action — so left open they are a silent capture trigger for any installed app.
///
/// iOS offers no reliable caller identity here (`sourceApplication` is absent through SwiftUI's
/// `onOpenURL` and unreliable generally), so trust is established by a shared secret instead: the
/// app mints a random token into the app-group container, the first-party producers that live in
/// that group (the widgets) stamp it onto the links they build, and the app requires it on any link
/// that acts. A third-party app cannot read another app's group container, so it cannot mint a
/// link that passes.
///
/// Compiled into **both** the app and the widget extension — the producer and the consumer must
/// agree on the query name and the policy, so they share one file.
enum DeepLinkTrust {
    /// The shared App Group — a storage key, owned by `SharedAppState.appGroup`, which is compiled
    /// into the same two targets as this file.
    static let appGroupID = SharedAppState.appGroup

    /// Query item carrying the token. Short because widget links are built by hand.
    static let queryName = "k"

    private static let defaultsKey = "deepLinkTrustToken"

    /// Test seam: when set, used instead of the real app-group defaults.
    static var testDefaults: UserDefaults?

    private static var store: UserDefaults? {
        testDefaults ?? UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Token lifecycle

    /// The current token, or `nil` if one has never been minted.
    static var current: String? {
        store?.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Mint a token if there isn't one. Called by the app at launch, before any URL can be handled,
    /// so the app side is never the reason a link fails to validate.
    @discardableResult
    static func ensureToken() -> String? {
        if let existing = current { return existing }
        guard let store else { return nil }
        let token = makeToken()
        store.set(token, forKey: defaultsKey)
        return token
    }

    /// 128 bits, URL-safe. Not a credential — a capability token for one process boundary.
    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Producing (widgets)

    /// Stamp the token onto a first-party deep link. Returns the URL unchanged when no token
    /// exists (the app has never launched), in which case an acting link is simply ignored.
    static func sign(_ urlString: String) -> String {
        guard let token = current else { return urlString }
        let separator = urlString.contains("?") ? "&" : "?"
        return "\(urlString)\(separator)\(queryName)=\(token)"
    }

    /// Convenience for the widgets, which need a non-optional `URL`.
    static func signedURL(_ urlString: String) -> URL? { URL(string: sign(urlString)) }

    // MARK: - Consuming (app)

    /// Whether `url` carries the current token. Constant-time compare — the token is short-lived
    /// only in the sense that it never rotates, so don't leak it a byte at a time through timing.
    static func isTrusted(_ url: URL) -> Bool {
        guard let expected = current, !expected.isEmpty else { return false }
        let presented = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == queryName }?.value
        guard let presented, !presented.isEmpty else { return false }
        return constantTimeEquals(presented, expected)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for (i, j) in zip(x, y) { diff |= i ^ j }
        return diff == 0
    }

    // MARK: - Policy

    /// Whether a link makes the app *do* something, and so may only be honoured from a caller that
    /// proved it is first-party.
    ///
    /// The dividing line is capability: a link that captures, listens, or actuates needs trust; one
    /// that only navigates or *reduces* what the app is doing does not. Disconnecting the glasses
    /// and turning listening off stay open on purpose — a hostile caller gains nothing by stopping
    /// the microphone, and gating them would break the "panic off" path for no benefit.
    ///
    /// Pure, and the single place the policy lives, so the classification is testable directly.
    static func requiresTrustedCaller(host: String?, action: String) -> Bool {
        let action = action.lowercased()
        switch host {
        case "action":
            // ask / photo / describe — capture a frame, or open the mic.
            return true
        case "listen":
            return action != "off"
        case "quickaction":
            // Runs a user-configured action; contents are arbitrary.
            return true
        case "persona":
            // Applies persona routing and then immediately starts a listening turn.
            return true
        case "connect":
            // `connectAndListen` — brings up the glasses and opens the mic.
            return true
        case "disconnect":
            return false
        default:
            // Unknown hosts do nothing today; the Wearables SDK callback path is separate.
            return false
        }
    }
}
