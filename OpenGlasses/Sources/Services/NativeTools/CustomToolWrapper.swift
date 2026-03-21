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

        var urlString = "shortcuts://run-shortcut?name=\(shortcutName)"

        // Pass the first string argument as input text
        if let firstValue = args.values.first {
            let inputText = "\(firstValue)"
            if let encoded = inputText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&input=text&text=\(encoded)"
            }
        }

        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else {
            return "Couldn't build URL for shortcut '\(shortcutName)'."
        }

        let canOpen = await MainActor.run {
            UIApplication.shared.canOpenURL(url)
        }

        guard canOpen else {
            return "Can't open Shortcuts app. Is '\(shortcutName)' installed?"
        }

        await MainActor.run {
            UIApplication.shared.open(url)
        }
        return "Running shortcut '\(shortcutName)'."
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
