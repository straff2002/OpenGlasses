import UIKit

/// Runs one of the wearer's Shortcuts by name and waits for what it hands back: the one round trip
/// `run_shortcut` and every Shortcut-backed custom tool share.
///
/// The app opens `shortcuts://x-callback-url/run-shortcut` with three return links that carry a
/// one-shot token (`ShortcutCallbackManager`), and only a callback carrying that token resolves
/// the wait. What comes back is the Shortcut's own output — mail, messages, a page — so the caller
/// never sees it unframed: `run_shortcut` is named in `PromptInjectionPolicy.untrustedOutputTools`
/// and a custom tool is `isUserDefined`.
///
/// iOS opens Shortcuts for an app in the foreground only, and no public API runs a Shortcut from
/// the background. So nothing is opened unless the app is active: the call says plainly that
/// Shortcuts run only while Avenkin is open, rather than reporting a run that never started.
@MainActor
enum ShortcutRunner {
    /// How long a run waits for the Shortcut's callback.
    static let callbackTimeout: TimeInterval = 30

    /// What a call made while the app is not in front returns. Nothing was opened.
    static let notInForegroundMessage =
        "Shortcuts can only be run while Avenkin is open, so this one was not run. Nothing was started."

    /// Whether the app is in front, where iOS lets it open Shortcuts.
    static func appIsActive() -> Bool {
        UIApplication.shared.applicationState == .active
    }

    /// The x-callback URL that runs `shortcutName` with `input` as text and returns to the app with
    /// `callbackToken`. Nil for an empty name. Pure, for tests.
    static func runURL(shortcutName: String, input: String?, callbackToken: String) -> URL? {
        guard !shortcutName.isEmpty, let name = queryValue(shortcutName) else { return nil }
        var url = "shortcuts://x-callback-url/run-shortcut?name=\(name)"
        if let input, let text = queryValue(input) {
            url += "&input=text&text=\(text)"
        }
        // The token rides unencoded, as these callback values always have: `?` and `=` are legal
        // inside a query value, and the token's base64url alphabet has no `&` to break out of it.
        let cb = "\(ShortcutCallbackManager.queryName)=\(callbackToken)"
        url += "&x-success=openglasses://shortcut-result?\(cb)"
        url += "&x-cancel=openglasses://shortcut-cancel?\(cb)"
        url += "&x-error=openglasses://shortcut-error?\(cb)"
        return URL(string: url)
    }

    /// What a run that heard nothing back returns. The Shortcut may still be running, so it never
    /// says the Shortcut finished.
    static func noReplyMessage(shortcutName: String) -> String {
        "Shortcut '\(shortcutName)' sent nothing back within \(Int(callbackTimeout)) seconds. It may still be running."
    }

    /// Run `shortcutName` and return its output, the reason it couldn't run, or `noReplyMessage`.
    /// - Parameter isAppActive: whether the app is in front; tests pass their own.
    static func run(shortcutName: String, input: String?, toolName: String,
                    isAppActive: @MainActor () -> Bool = ShortcutRunner.appIsActive) async -> String {
        guard isAppActive() else {
            // A fixed tool label: a custom tool's name is the wearer's own words.
            PrivacyLog.toolRun(.failed, tool: "run_shortcut", detail: PrivacyToken("notInForeground"))
            return notInForegroundMessage
        }
        let callbackToken = ShortcutCallbackManager.makeCallbackToken()
        guard let url = runURL(shortcutName: shortcutName, input: input, callbackToken: callbackToken) else {
            return "Couldn't build a link for Shortcut '\(shortcutName)'."
        }
        guard UIApplication.shared.canOpenURL(url) else {
            return "The Shortcuts app isn't available, so Shortcut '\(shortcutName)' was not run."
        }

        ShortcutCallbackManager.shared.setPending(toolName: toolName, callbackToken: callbackToken)
        let opened = await UIApplication.shared.open(url)
        guard opened else {
            ShortcutCallbackManager.shared.cancelPending(callbackToken: callbackToken)
            return "Shortcuts didn't open, so Shortcut '\(shortcutName)' was not run."
        }
        let result = await ShortcutCallbackManager.shared.waitForResult(timeout: callbackTimeout)
        return result ?? noReplyMessage(shortcutName: shortcutName)
    }

    /// A query value with every delimiter encoded, so a name or input holding `&`, `=`, `+`, `#`
    /// or `?` stays one value instead of breaking the link.
    private static func queryValue(_ raw: String) -> String? {
        raw.addingPercentEncoding(withAllowedCharacters: valueCharacters)
    }

    private static let valueCharacters = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&=+#?/"))
}
