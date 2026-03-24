import Foundation
import Intents
import UIKit

/// Tool that lets the agent discover available capabilities on the device
/// and reason about how to combine them into useful scheduled tasks.
///
/// Discovery sources:
/// - App-donated Siri shortcuts (via INVoiceShortcutCenter)
/// - Installed apps (via canOpenURL for known URL schemes)
/// - Available native tools (from the registry)
/// - Connected MCP servers and their tools
/// - User's existing quick actions and scheduled tasks
///
/// The agent uses this to propose new automations to the operator.
struct DiscoverCapabilitiesTool: NativeTool {
    let name = "discover_capabilities"
    let description = """
        Discover what the device can do — installed apps, available Siri Shortcuts, \
        connected services, and existing scheduled tasks. Use this to find new ways \
        to be useful. After discovering capabilities, reason about what combinations \
        would be valuable and suggest new scheduled tasks or quick actions to the operator.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "category": [
                "type": "string",
                "description": "What to discover: 'all', 'shortcuts', 'apps', 'tools', 'tasks', 'suggest'",
                "enum": ["all", "shortcuts", "apps", "tools", "tasks", "suggest"]
            ]
        ]
    ]

    weak var toolRegistry: NativeToolRegistry?

    func execute(args: [String: Any]) async throws -> String {
        let category = (args["category"] as? String) ?? "all"

        var sections: [String] = []

        if category == "all" || category == "shortcuts" {
            sections.append(await discoverShortcuts())
        }
        if category == "all" || category == "apps" {
            sections.append(await discoverApps())
        }
        if category == "all" || category == "tools" {
            sections.append(await discoverTools())
        }
        if category == "all" || category == "tasks" {
            sections.append(await discoverTasks())
        }
        if category == "suggest" {
            sections.append(generateSuggestions())
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Discovery

    private func discoverShortcuts() async -> String {
        var lines = ["## Available Siri Shortcuts"]

        // Get voice shortcuts donated by apps
        do {
            let shortcuts = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[INVoiceShortcut], Error>) in
                INVoiceShortcutCenter.shared.getAllVoiceShortcuts { shortcuts, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: shortcuts ?? []) }
                }
            }

            if shortcuts.isEmpty {
                lines.append("No Siri Shortcuts found. The operator can create Shortcuts in the Shortcuts app that I can call.")
            } else {
                for shortcut in shortcuts {
                    let phrase = shortcut.invocationPhrase
                    let title = shortcut.shortcut.intent?.description ?? shortcut.shortcut.userActivity?.title ?? "Unknown"
                    lines.append("- \"\(phrase)\" → \(title)")
                }
            }
        } catch {
            lines.append("Could not query shortcuts: \(error.localizedDescription)")
            lines.append("The operator can still tell me shortcut names to call.")
        }

        return lines.joined(separator: "\n")
    }

    private func discoverApps() async -> String {
        var lines = ["## Installed Apps Detected"]

        // Check known URL schemes to see what's installed
        let appsToCheck: [(String, String, String)] = [
            // (scheme, name, category)
            ("mailto:", "Apple Mail", "Communication"),
            ("message:", "Messages", "Communication"),
            ("whatsapp://", "WhatsApp", "Communication"),
            ("tg://", "Telegram", "Communication"),
            ("weixin://", "WeChat", "Communication"),
            ("kakaotalk://", "KakaoTalk", "Communication"),
            ("line://", "LINE", "Communication"),
            ("fb://", "Facebook", "Social"),
            ("instagram://", "Instagram", "Social"),
            ("twitter://", "X/Twitter", "Social"),
            ("sinaweibo://", "Weibo", "Social"),
            ("xhsdiscover://", "Xiaohongshu", "Social"),
            ("bilibili://", "Bilibili", "Entertainment"),
            ("spotify://", "Spotify", "Music"),
            ("music://", "Apple Music", "Music"),
            ("youtube://", "YouTube", "Entertainment"),
            ("nflx://", "Netflix", "Entertainment"),
            ("comgooglemaps://", "Google Maps", "Navigation"),
            ("baidumap://", "Baidu Maps", "Navigation"),
            ("iosamap://", "Amap/Gaode", "Navigation"),
            ("uber://", "Uber", "Transport"),
            ("lyft://", "Lyft", "Transport"),
            ("alipay://", "Alipay", "Finance"),
            ("taobao://", "Taobao", "Shopping"),
            ("meituan://", "Meituan", "Food"),
            ("eleme://", "Ele.me", "Food"),
            ("shortcuts://", "Shortcuts", "Automation"),
        ]

        var installed: [(String, String)] = []  // (name, category)

        for (scheme, name, category) in appsToCheck {
            if let url = URL(string: scheme) {
                let canOpen = await MainActor.run { UIApplication.shared.canOpenURL(url) }
                if canOpen {
                    installed.append((name, category))
                }
            }
        }

        if installed.isEmpty {
            lines.append("No recognized apps detected (URL scheme checks may be restricted).")
        } else {
            let grouped = Dictionary(grouping: installed, by: { $0.1 })
            for (category, apps) in grouped.sorted(by: { $0.key < $1.key }) {
                lines.append("**\(category):** \(apps.map(\.0).joined(separator: ", "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func discoverTools() async -> String {
        var lines = ["## Available Native Tools"]

        if let registry = await MainActor.run(body: { toolRegistry }) {
            let names = await MainActor.run { registry.toolNames.sorted() }
            lines.append("\(names.count) tools available: \(names.joined(separator: ", "))")
        } else {
            lines.append("Tool registry not available.")
        }

        // MCP servers
        let mcpServers = Config.mcpServers
        if !mcpServers.isEmpty {
            lines.append("\n**MCP Servers:** \(mcpServers.count) connected")
        }

        return lines.joined(separator: "\n")
    }

    private func discoverTasks() async -> String {
        var lines = ["## Current Scheduled Tasks"]

        let tasks = await MainActor.run { AgentScheduler.savedTasks() }
        if tasks.isEmpty {
            lines.append("No scheduled tasks. I can create them with manage_schedule.")
        } else {
            for task in tasks {
                let status = task.enabled ? "✓" : "✗"
                let interval = task.intervalMinutes == 0 ? "daily" : "\(task.intervalMinutes)min"
                lines.append("- [\(status)] \(task.name) (\(interval))")
            }
        }

        // Quick actions
        let actions = Config.quickActions
        lines.append("\n**Quick Actions:** \(actions.map(\.label).joined(separator: ", "))")

        return lines.joined(separator: "\n")
    }

    private func generateSuggestions() -> String {
        return """
        ## How to Suggest Improvements

        Based on what you discovered, think about:
        1. What Shortcuts exist that could be checked on a schedule?
        2. What installed apps have data the operator might want summarized?
        3. What native tools could be combined into useful automated workflows?
        4. What quick actions would save the operator time?

        Then tell the operator your suggestions conversationally. For each suggestion:
        - What it does
        - Why it would be useful
        - How often it should run
        - Ask if they'd like you to set it up

        If they agree, use manage_schedule to create the task.
        """
    }
}
