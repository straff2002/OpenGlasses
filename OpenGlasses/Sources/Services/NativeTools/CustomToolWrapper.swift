import UIKit

/// Wraps a user-defined CustomToolDefinition to conform to the NativeTool protocol.
/// Executes by opening a Siri Shortcut or URL scheme.
///
/// The wearer defined it, so it is not one of the app's own tools (`isUserDefined`): whatever it
/// returns reaches the model framed as untrusted data. A Shortcut's output is outside text — mail,
/// messages, a page. A link's reply is only this file's fixed words with the model's own
/// arguments in them, which needs no framing; it is framed anyway, since one rule for every
/// custom tool is the rule a new kind of custom tool can't slip past.
struct CustomToolWrapper: NativeTool {
    let definition: CustomToolDefinition
    /// Whether the app is in front, where iOS lets it open Shortcuts; tests pass their own.
    var isAppActive: @MainActor () -> Bool = { ShortcutRunner.appIsActive() }

    var isUserDefined: Bool { true }

    var name: String { definition.name }
    var description: String { definition.description }

    var parametersSchema: [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for param in definition.parameters {
            properties[param.name] = [
                "type": param.type,
                "description": param.description,
            ] as [String: Any]
            if param.required {
                required.append(param.name)
            }
        }
        return [
            "type": "object",
            "properties": properties,
            "required": required,
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        switch definition.actionType {
        case .shortcut:
            return await executeShortcut(args: args)
        case .urlScheme:
            return await executeURLScheme(args: args)
        }
    }

    private func executeShortcut(args: [String: Any]) async -> String {
        guard let shortcutName = definition.shortcutName, !shortcutName.isEmpty else {
            return "No shortcut name configured for tool '\(name)'."
        }
        // The first argument rides as the Shortcut's text input. The run, its token-checked
        // callback and the foreground rule are `ShortcutRunner`'s, shared with `run_shortcut`.
        let input = args.values.first.map { "\($0)" }
        return await ShortcutRunner.run(shortcutName: shortcutName, input: input, toolName: name,
                                        isAppActive: isAppActive)
    }

    private func executeURLScheme(args: [String: Any]) async -> String {
        guard var template = definition.urlTemplate, !template.isEmpty else {
            return "No URL template configured for tool '\(name)'."
        }

        // Replace {{paramName}} placeholders with actual values
        for (key, value) in args {
            let placeholder = "{{\(key)}}"
            let replacement = "\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(value)"
            template = template.replacingOccurrences(of: placeholder, with: replacement)
        }

        guard let url = URL(string: template) else {
            return "Invalid URL after substitution: \(template)"
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }
        return "Opened URL for '\(name)'."
    }
}
