import UIKit

/// Wraps a user-defined CustomToolDefinition to conform to the NativeTool protocol.
/// Executes by opening a Siri Shortcut or URL scheme.
struct CustomToolWrapper: NativeTool {
    let definition: CustomToolDefinition

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

        guard let encodedName = shortcutName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return "Invalid shortcut name."
        }

        // Use x-callback-url to get the shortcut's result back
        var urlString = "shortcuts://x-callback-url/run-shortcut?name=\(encodedName)"

        // Pass the first string argument as input text
        if let firstValue = args.values.first {
            let inputText = "\(firstValue)"
            if let encoded = inputText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&input=text&text=\(encoded)"
            }
        }

        // Callback URLs — the shortcut will redirect back to OpenGlasses with results
        urlString += "&x-success=openglasses://shortcut-result"
        urlString += "&x-cancel=openglasses://shortcut-cancel"
        urlString += "&x-error=openglasses://shortcut-error"

        guard let url = URL(string: urlString) else {
            return "Couldn't build URL for shortcut '\(shortcutName)'."
        }

        let canOpen = await MainActor.run {
            UIApplication.shared.canOpenURL(url)
        }

        guard canOpen else {
            return "Can't open Shortcuts app. Is '\(shortcutName)' installed?"
        }

        // Store a pending callback so the URL handler can resolve it
        ShortcutCallbackManager.shared.setPending(toolName: name)

        await MainActor.run {
            UIApplication.shared.open(url)
        }

        // Wait for the callback (up to 30 seconds)
        let result = await ShortcutCallbackManager.shared.waitForResult(timeout: 30)
        return result ?? "Shortcut '\(shortcutName)' completed (no output returned)."
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
