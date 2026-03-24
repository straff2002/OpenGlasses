import SwiftUI
import UIKit

/// Pre-built Shortcut templates that users can preview, select, and install.
/// Each template creates a Siri Shortcut + a matching scheduled task.
struct ShortcutTemplatesView: View {
    @EnvironmentObject var appState: AppState
    @State private var templates = ShortcutTemplate.allTemplates
    @State private var expandedId: String?
    @State private var installResult: String?

    var body: some View {
        List {
            Section {
                ForEach($templates) { $template in
                    VStack(alignment: .leading, spacing: 0) {
                        // Header row — toggle + name + category badge
                        Button {
                            withAnimation { expandedId = expandedId == template.id ? nil : template.id }
                        } label: {
                            HStack(spacing: 12) {
                                Toggle("", isOn: $template.selected)
                                    .labelsHidden()
                                    .tint(.accentColor)

                                Image(systemName: template.icon)
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(template.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }

                                Spacer()

                                Image(systemName: expandedId == template.id ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Expandable detail
                        if expandedId == template.id {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(template.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)

                                // What the Shortcut does
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Shortcut Steps", systemImage: "arrow.triangle.branch")
                                        .font(.caption.weight(.medium))
                                    Text(template.shortcutSteps)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 6))
                                }

                                // What the agent does with it
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("Agent Behavior", systemImage: "brain")
                                        .font(.caption.weight(.medium))
                                    Text(template.agentBehavior)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                // Schedule
                                HStack {
                                    Label("Schedule", systemImage: "clock")
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    Text(template.scheduleDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.leading, 52) // Align with text
                            .padding(.bottom, 8)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Shortcut Templates")
                    Spacer()
                    Text("\(templates.filter(\.selected).count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Each template creates a Siri Shortcut and a matching scheduled task. Tap to preview what it does before installing.")
            }

            // Install button
            let selectedCount = templates.filter(\.selected).count
            if selectedCount > 0 {
                Section {
                    Button {
                        installSelected()
                    } label: {
                        Label("Install \(selectedCount) Shortcut\(selectedCount == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                    }

                    if let result = installResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Creates scheduled tasks in the app. For the actual Siri Shortcuts, you'll be guided to create them in the Shortcuts app.")
                }
            }

            // How it works
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How it works", systemImage: "info.circle")
                        .font(.footnote.weight(.medium))
                    Text("1. Select the templates you want")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("2. Tap Install — this creates scheduled tasks in the app")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("3. Create the matching Shortcuts in the Shortcuts app (we'll show you how)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("4. The agent runs each Shortcut on schedule and summarizes results")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Shortcut Templates")
    }

    private func installSelected() {
        let selected = templates.filter(\.selected)
        var created = 0

        for template in selected {
            // Create the scheduled task
            var tasks = AgentScheduler.savedTasks()
            // Skip if already installed
            if tasks.contains(where: { $0.id == template.taskId }) { continue }

            let task = AgentScheduler.ScheduledTask(
                id: template.taskId,
                name: template.name,
                prompt: template.taskPrompt,
                intervalMinutes: template.intervalMinutes,
                enabled: true,
                speakResult: template.speakResult
            )
            tasks.append(task)
            AgentScheduler.saveTasks(tasks)
            created += 1
        }

        installResult = created > 0
            ? "Created \(created) scheduled task\(created == 1 ? "" : "s"). Now create the matching Shortcuts in the Shortcuts app."
            : "All selected templates are already installed."
    }
}

// MARK: - Template Model

struct ShortcutTemplate: Identifiable {
    let id: String
    let name: String
    let icon: String
    let category: String
    let description: String
    let shortcutSteps: String       // What the Shortcut does (human-readable)
    let agentBehavior: String       // What the agent does with the output
    let scheduleDescription: String
    let taskId: String              // ID for the scheduled task
    let taskPrompt: String          // The prompt the agent runs
    let intervalMinutes: Int
    let speakResult: Bool
    var selected: Bool = false

    static let allTemplates: [ShortcutTemplate] = [
        // MARK: Communication
        ShortcutTemplate(
            id: "email-check",
            name: "Check Email",
            icon: "envelope",
            category: "Communication",
            description: "Checks Apple Mail for unread emails and summarizes urgent ones.",
            shortcutSteps: "1. Find Emails (Unread, Last 1 Hour)\n2. Get Subject + Sender for each\n3. Output as text list",
            agentBehavior: "Reads the email summaries, identifies urgent ones, and only notifies you about those. Routine newsletters and promotions are silently ignored.",
            scheduleDescription: "Every 15 minutes",
            taskId: "shortcut-email-check",
            taskPrompt: "Run the Siri Shortcut 'Check Email' to get recent unread emails. Review the results. Only report emails that are urgent, from important contacts, or require action. Ignore newsletters, marketing, and automated notifications. If nothing urgent, there's nothing to report.",
            intervalMinutes: 15,
            speakResult: true
        ),
        ShortcutTemplate(
            id: "message-check",
            name: "Check Messages",
            icon: "message",
            category: "Communication",
            description: "Checks for recent unread iMessages and summarizes them.",
            shortcutSteps: "1. Find Messages (Unread)\n2. Get Sender + Content preview\n3. Output as text list",
            agentBehavior: "Summarizes who messaged you and what about. Groups by sender if multiple messages from the same person.",
            scheduleDescription: "Every 10 minutes",
            taskId: "shortcut-message-check",
            taskPrompt: "Run the Siri Shortcut 'Check Messages' to get recent unread messages. Briefly summarize who messaged and what about. Group messages by sender. If no unread messages, there's nothing to report.",
            intervalMinutes: 10,
            speakResult: true
        ),

        // MARK: Productivity
        ShortcutTemplate(
            id: "daily-agenda",
            name: "Daily Agenda",
            icon: "calendar",
            category: "Productivity",
            description: "Morning summary of today's calendar, reminders, and weather.",
            shortcutSteps: "1. Get Calendar Events (Today)\n2. Get Reminders (Due Today)\n3. Get Current Weather\n4. Combine into summary text",
            agentBehavior: "Reads the combined data and presents a natural morning briefing. Highlights conflicts, back-to-back meetings, and weather that might affect plans.",
            scheduleDescription: "Once daily (morning)",
            taskId: "shortcut-daily-agenda",
            taskPrompt: "Run the Siri Shortcut 'Daily Agenda' for today's schedule. Present it as a natural morning briefing: events in order, any reminders due, and weather. Note any scheduling conflicts or unusually long gaps.",
            intervalMinutes: 0,
            speakResult: true
        ),
        ShortcutTemplate(
            id: "focus-timer",
            name: "Focus Session",
            icon: "timer",
            category: "Productivity",
            description: "Starts a focus/pomodoro timer and silences notifications.",
            shortcutSteps: "1. Set Focus Mode (Do Not Disturb)\n2. Start Timer (25 min)\n3. When done: Turn off DND\n4. Output 'Focus session complete'",
            agentBehavior: "Announces when the focus session starts and ends. Can suggest a break after completion.",
            scheduleDescription: "On demand only",
            taskId: "shortcut-focus-timer",
            taskPrompt: "Run the Siri Shortcut 'Focus Session' to start a 25-minute focus timer. Announce that the focus session has started and you'll let them know when it's done.",
            intervalMinutes: 0,
            speakResult: true
        ),

        // MARK: Health
        ShortcutTemplate(
            id: "health-summary",
            name: "Health Summary",
            icon: "heart",
            category: "Health",
            description: "Reads step count, active calories, and exercise minutes from HealthKit.",
            shortcutSteps: "1. Get Health Sample (Steps, Today)\n2. Get Health Sample (Active Calories)\n3. Get Health Sample (Exercise Minutes)\n4. Output as text",
            agentBehavior: "Presents a brief health update. Compares to daily goals if known from memory. Encourages if behind, congratulates if ahead.",
            scheduleDescription: "Every 2 hours",
            taskId: "shortcut-health-summary",
            taskPrompt: "Run the Siri Shortcut 'Health Summary' to get today's health data. Present steps, calories, and exercise minutes naturally. Compare to any goals you know about from memory. Only report if there's something noteworthy (close to goal, unusually low, etc.).",
            intervalMinutes: 120,
            speakResult: true
        ),

        // MARK: Smart Home
        ShortcutTemplate(
            id: "home-status",
            name: "Home Status",
            icon: "house",
            category: "Smart Home",
            description: "Checks if any doors/windows are open or lights left on.",
            shortcutSteps: "1. Get Home accessories state\n2. Filter: doors open, lights on\n3. Output status text",
            agentBehavior: "Only alerts if something is unexpected — a door left open, lights on in empty rooms. Stays quiet if everything is normal.",
            scheduleDescription: "Every 30 minutes",
            taskId: "shortcut-home-status",
            taskPrompt: "Run the Siri Shortcut 'Home Status' to check smart home state. Only report if something needs attention — doors left open, lights on when they shouldn't be, unusual sensor readings. If everything looks normal, there's nothing to report.",
            intervalMinutes: 30,
            speakResult: true
        ),

        // MARK: News & Information
        ShortcutTemplate(
            id: "news-briefing",
            name: "News Briefing",
            icon: "newspaper",
            category: "Information",
            description: "Fetches top headlines from Apple News or RSS feeds.",
            shortcutSteps: "1. Get Articles from Apple News\n2. Filter: Top 5 headlines\n3. Get Title + Source for each\n4. Output as text list",
            agentBehavior: "Summarizes the top stories in 2-3 sentences. Skips topics the user has indicated they're not interested in (from memory).",
            scheduleDescription: "Every 2 hours",
            taskId: "shortcut-news-briefing",
            taskPrompt: "Run the Siri Shortcut 'News Briefing' for top headlines. Summarize the most important 2-3 stories in spoken format. Skip topics the user isn't interested in (check memory). If nothing noteworthy, there's nothing to report.",
            intervalMinutes: 120,
            speakResult: true
        ),

        // MARK: Travel
        ShortcutTemplate(
            id: "commute-check",
            name: "Commute Check",
            icon: "car",
            category: "Travel",
            description: "Checks travel time to work/home and alerts about delays.",
            shortcutSteps: "1. Get Travel Time (Home → Work)\n2. Compare to normal duration\n3. Output time + any delays",
            agentBehavior: "Only alerts if the commute is significantly longer than usual (traffic, accidents). Stays quiet if normal.",
            scheduleDescription: "Weekday mornings",
            taskId: "shortcut-commute-check",
            taskPrompt: "Run the Siri Shortcut 'Commute Check' for current travel time. Only report if travel time is significantly longer than usual or there are notable delays. If the commute looks normal, there's nothing to report.",
            intervalMinutes: 0,
            speakResult: true
        ),
    ]
}
