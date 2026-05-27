import Foundation

/// Lets the LLM list and execute user-configured Quick Actions and Siri Shortcuts.
///
/// Quick Actions are pre-configured speed dial buttons (photo prompts, Home Assistant
/// commands, Siri Shortcuts, etc.) that the user sets up in Settings. This tool exposes
/// them to the LLM so it can chain actions together autonomously.
///
/// Siri Shortcuts can also be listed and run directly by name.
struct QuickActionTool: NativeTool {
    let name = "quick_action"
    let description = """
        List or run the user's configured Quick Actions and Siri Shortcuts. \
        Quick Actions are pre-configured automations (photo analysis, smart home commands, \
        shortcuts, prompts). Use action "list" to see available actions and shortcuts, \
        or "run" to execute one by name. You can chain multiple actions in sequence.
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["list", "run"],
                "description": "Whether to list available actions or run one"
            ],
            "name": [
                "type": "string",
                "description": "The label/name of the Quick Action or Siri Shortcut to run (required for 'run')"
            ]
        ],
        "required": ["action"]
    ]

    /// Weak reference to AppState for executing actions. Set during registration.
    weak var appState: AppStateProtocol?

    func execute(args: [String: Any]) async throws -> String {
        let action = args["action"] as? String ?? "list"

        switch action {
        case "list":
            return await listActions()
        case "run":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "Please specify the name of the Quick Action or Siri Shortcut to run."
            }
            return await runAction(named: name)
        default:
            return "Unknown action '\(action)'. Use 'list' or 'run'."
        }
    }

    // MARK: - List

    private func listActions() async -> String {
        var sections: [String] = []

        // Quick Actions
        let actions = Config.quickActions
        if actions.isEmpty {
            sections.append("## Quick Actions\nNo quick actions configured. The user can add them in Settings → Quick Actions.")
        } else {
            var lines = ["## Quick Actions (\(actions.count))"]
            for qa in actions {
                var detail = "[\(qa.type.displayName)]"
                switch qa.type {
                case .prompt:
                    if let p = qa.promptText { detail += " \(p.prefix(80))" }
                case .photoThenPrompt:
                    if let p = qa.promptText { detail += " \(p.prefix(80))" }
                case .photo:
                    detail += " Capture and describe"
                case .homeAssistant:
                    detail += " \(qa.haService ?? "") → \(qa.haEntityId ?? "all")"
                case .siriShortcut:
                    detail += " \(qa.shortcutName ?? "")"
                case .openApp:
                    detail += " \(qa.urlScheme ?? "")"
                }
                lines.append("- **\(qa.label)**: \(detail)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        // Siri Shortcuts
        let shortcuts = await discoverShortcuts()
        sections.append(shortcuts)

        return sections.joined(separator: "\n\n")
    }

    private func discoverShortcuts() async -> String {
        var lines = ["## Siri Shortcuts"]

        do {
            let shortcuts = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[INVoiceShortcut], Error>) in
                INVoiceShortcutCenter.shared.getAllVoiceShortcuts { shortcuts, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: shortcuts ?? []) }
                }
            }

            if shortcuts.isEmpty {
                lines.append("No Siri Shortcuts found. The user can create them in the Shortcuts app.")
            } else {
                for shortcut in shortcuts {
                    let phrase = shortcut.invocationPhrase
                    let title = shortcut.shortcut.intent?.description ?? shortcut.shortcut.userActivity?.title ?? phrase
                    lines.append("- **\(phrase)**: \(title)")
                }
            }
        } catch {
            lines.append("Could not query shortcuts: \(error.localizedDescription)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Run

    private func runAction(named name: String) async -> String {
        let lowerName = name.lowercased()

        // Try Quick Actions first (match by label, case-insensitive)
        let actions = Config.quickActions
        if let match = actions.first(where: { $0.label.lowercased() == lowerName }) {
            return await executeQuickAction(match)
        }

        // Fuzzy match on Quick Actions
        if let match = actions.first(where: { $0.label.lowercased().contains(lowerName) || lowerName.contains($0.label.lowercased()) }) {
            return await executeQuickAction(match)
        }

        // Try as a Siri Shortcut name
        return await runShortcut(named: name)
    }

    private func executeQuickAction(_ action: QuickAction) async -> String {
        guard let appState = await MainActor.run(body: { self.appState }) else {
            return "App state not available — cannot execute quick action."
        }

        await appState.executeQuickAction(action)
        return "Executed quick action '\(action.label)' [\(action.type.displayName)]."
    }

    private func runShortcut(named name: String) async -> String {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
            return "Couldn't build URL for shortcut '\(name)'."
        }

        let opened = await MainActor.run {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }

        return opened ? "Running Siri Shortcut '\(name)'." : "Failed to open Shortcuts app."
    }
}

import UIKit
import Intents

/// Protocol so QuickActionTool can call executeQuickAction without importing the full AppState.
@MainActor
protocol AppStateProtocol: AnyObject {
    func executeQuickAction(_ action: QuickAction) async
}
