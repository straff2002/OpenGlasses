import Foundation

/// Runs Siri Shortcuts (Apple Shortcuts app) by name and returns their output.
/// Allows the user to trigger any shortcut they've created hands-free, while the app is open.
struct SiriShortcutsTool: NativeTool {
    let name = "run_shortcut"
    let description = "Run an Apple Shortcut by name and get back what it outputs. Works only while the app is open. Great for custom automations like 'start focus mode', 'log water', or any shortcut the user has created."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "shortcut_name": [
                "type": "string",
                "description": "The name of the Shortcut to run (e.g. 'Start Focus', 'Log Water', 'Morning Routine')"
            ],
            "input": [
                "type": "string",
                "description": "Optional text input to pass to the shortcut"
            ]
        ],
        "required": ["shortcut_name"]
    ]

    /// Whether the app is in front, where iOS lets it open Shortcuts; tests pass their own.
    var isAppActive: @MainActor () -> Bool = { ShortcutRunner.appIsActive() }

    /// Runs the Shortcut and returns what it hands back over x-callback-url, through the same
    /// token-checked round trip as a custom Shortcut tool (`ShortcutRunner`). The output is the
    /// Shortcut's, so `PromptInjectionPolicy` frames it as untrusted data. Outside the foreground
    /// nothing is opened, and the reply says so rather than claiming a run.
    func execute(args: [String: Any]) async throws -> String {
        guard let shortcutName = (args["shortcut_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !shortcutName.isEmpty else {
            return "No shortcut name provided."
        }
        return await ShortcutRunner.run(shortcutName: shortcutName, input: args["input"] as? String,
                                        toolName: name, isAppActive: isAppActive)
    }
}
