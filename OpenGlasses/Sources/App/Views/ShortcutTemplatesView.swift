import SwiftUI
import UIKit

/// Pre-built Shortcut templates that users can preview, select, and install.
/// Installing one creates its scheduled task, switched off: the task runs a Siri Shortcut the
/// person builds themselves, and until that Shortcut exists every run would fail.
///
/// Check Email and Check Messages are automation templates instead (`Setup.automation`). As
/// scheduled tasks they never worked: the app can open Shortcuts only from the foreground, a plain
/// run returned nothing to read, and with agent mode on every run waited for an approval or was
/// held while the person was away (field report, build 770). Now the person's own Shortcuts
/// automation hands the mail to `ReviewEmailIntent` and the messages to `ReviewMessagesIntent`,
/// which run in the background.
struct ShortcutTemplatesView: View {
    @EnvironmentObject var appState: AppState
    @State private var templates = ShortcutTemplate.allTemplates
    @State private var expandedId: String?
    @State private var installResult: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        List {
            Section {
                ForEach($templates) { $template in
                    VStack(alignment: .leading, spacing: 0) {
                        // Header row — toggle + name + category badge
                        Button {
                            withAnimation(reduceMotion ? nil : .default) {
                                expandedId = expandedId == template.id ? nil : template.id
                            }
                        } label: {
                            HStack(spacing: 12) {
                                // Named so VoiceOver doesn't reach an unnamed switch;
                                // `.labelsHidden()` only hides it visually.
                                Toggle(template.name, isOn: $template.selected)
                                    .labelsHidden()
                                    .tint(.accentColor)

                                Image(systemName: template.icon)
                                    .font(.title3)
                                    .foregroundStyle(Color(.label))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .foregroundStyle(Color(.label))
                                        .lineLimit(1)
                                    Text(template.category)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                }

                                Spacer()

                                Image(systemName: expandedId == template.id ? "chevron.up" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)

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
                                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
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
                Text("Most templates add a scheduled task that runs a Siri Shortcut you build yourself. Check Email and Check Messages are automations you set up in Shortcuts instead. Tap to preview what each does before installing.")
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
                    Text("Adds the scheduled tasks switched off. Build each Shortcut in the Shortcuts app, then switch its task on in Scheduled Tasks.")
                }
            }

            // How it works
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("How it works", systemImage: "info.circle")
                        .font(.footnote.weight(.medium))
                    Text("1. Select the templates you want")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("2. Tap Install — this adds their scheduled tasks, switched off")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("3. Build each Shortcut in the Shortcuts app, with the same name and the steps shown")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("4. Switch the task on in Scheduled Tasks. While Avenkin is open, the agent runs the Shortcut on schedule, and its results arrive as a silent notification unless you turn on Speak Result")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Shortcut Templates")
        .ogFormStyle()
    }

    private func installSelected() {
        let selected = templates.filter(\.selected)
        var created = 0

        for template in selected {
            // An automation template adds no task: its automation is built in Shortcuts.
            guard let task = template.scheduledTask else { continue }
            var tasks = AgentScheduler.savedTasks()
            // Skip if already installed
            if tasks.contains(where: { $0.id == task.id }) { continue }

            tasks.append(task)
            AgentScheduler.saveTasks(tasks)
            created += 1
        }

        let tasksLine = created == 1
            ? String(localized: "Added 1 scheduled task, switched off. Build the matching Shortcut in the Shortcuts app, then switch it on in Scheduled Tasks.")
            : created > 0
            ? String(localized: "Added \(created) scheduled tasks, switched off. Build the matching Shortcuts in the Shortcuts app, then switch them on in Scheduled Tasks.")
            : nil
        let automationNames = selected.filter { $0.setup == .automation }.map(\.name)
        let automationList = automationNames.formatted(.list(type: .and))
        let automationLine = automationNames.isEmpty ? nil
            : automationNames.count == 1
            ? String(localized: "\(automationList) adds no task here. Set up its automation in the Shortcuts app, with the steps shown.")
            : String(localized: "\(automationList) add no tasks here. Set up their automations in the Shortcuts app, with the steps shown.")
        installResult = [tasksLine, automationLine].compactMap { $0 }.joined(separator: " ")
        if installResult?.isEmpty ?? true {
            installResult = String(localized: "All selected templates are already installed.")
        }
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
    var taskId: String = ""         // ID for the scheduled task
    var taskPrompt: String = ""     // The prompt the agent runs
    var intervalMinutes: Int = 0
    var speakResult: Bool = AgentScheduler.ScheduledTask.speakResultDefault
    var setup: Setup = .scheduledTask
    var selected: Bool = false

    /// How a template is set up.
    enum Setup: Equatable {
        /// The app runs the person's Shortcut on a schedule. It works only while the app is in
        /// front, since iOS opens Shortcuts for an app in the foreground only.
        case scheduledTask
        /// The person's own Shortcuts automation runs on its schedule and hands its output to one
        /// of the app's actions, which runs in the background. Installing adds nothing: the
        /// automation is built in the Shortcuts app.
        case automation
    }

    /// The scheduled task installing this template adds, always switched off, or nil for an
    /// automation template, which adds none. The task runs a Shortcut the person has to build
    /// first, and the app can't tell whether they have, so they switch it on once they have.
    var scheduledTask: AgentScheduler.ScheduledTask? {
        guard setup == .scheduledTask, !taskId.isEmpty else { return nil }
        return AgentScheduler.ScheduledTask(
            id: taskId,
            name: name,
            prompt: taskPrompt,
            intervalMinutes: intervalMinutes,
            enabled: false,
            speakResult: speakResult
        )
    }

    static let allTemplates: [ShortcutTemplate] = [
        // MARK: Communication
        ShortcutTemplate(
            id: "email-check",
            name: "Check Email",
            icon: "envelope",
            category: String(localized: "Communication"),
            description: String(localized: "An automation you set up in Shortcuts finds your unread mail and hands it to Avenkin, which tells you only about the emails that need you. Avenkin never opens your mailbox itself."),
            shortcutSteps: String(localized: "1. Shortcuts › Automation › New › Time of Day: pick a time, Repeat Daily, Run Immediately\n2. Find Message (Mail): unread mail, received in the last hour, where the action offers those filters\n3. Review Email with Avenkin, with the found messages as Emails\nAdd one automation for each time of day you want a check."),
            agentBehavior: String(localized: "Reads only the text your automation hands it, and never acts on anything an email says. If an email is urgent, asks you to reply, or comes from a person rather than a mailing list, you get one silent notification. Newsletters and promotions are ignored."),
            scheduleDescription: String(localized: "When your automation runs"),
            setup: .automation
        ),
        ShortcutTemplate(
            id: "message-check",
            name: "Check Messages",
            icon: "message",
            category: String(localized: "Communication"),
            description: String(localized: "An automation you set up in Shortcuts finds your unread messages and hands them to Avenkin, which tells you only about the ones that need you. Avenkin never opens your messages itself."),
            shortcutSteps: String(localized: "1. Shortcuts › Automation › New › Time of Day: pick a time, Repeat Daily, Run Immediately\n2. Find Message (Messages): unread messages, where the action offers that filter\n3. Review Messages with Avenkin, with the found messages as Messages\nAdd one automation for each time of day you want a check."),
            agentBehavior: String(localized: "Reads only the text your automation hands it, and never acts on anything a message says. If someone asks you something, needs a reply, or writes about something time-sensitive, you get one silent notification. Codes, delivery notices and promotions are ignored, and a code is never repeated."),
            scheduleDescription: String(localized: "When your automation runs"),
            setup: .automation
        ),

        // MARK: Productivity
        ShortcutTemplate(
            id: "daily-agenda",
            name: "Daily Agenda",
            icon: "calendar",
            category: String(localized: "Productivity"),
            description: String(localized: "Morning summary of today's calendar, reminders, and weather."),
            shortcutSteps: String(localized: "1. Get Calendar Events (Today)\n2. Get Reminders (Due Today)\n3. Get Current Weather\n4. Combine into summary text"),
            agentBehavior: String(localized: "Reads the combined data and presents a natural morning briefing. Highlights conflicts, back-to-back meetings, and weather that might affect plans."),
            scheduleDescription: String(localized: "Once daily (morning)"),
            taskId: "shortcut-daily-agenda",
            taskPrompt: "Run the Siri Shortcut 'Daily Agenda' for today's schedule. Present it as a natural morning briefing: events in order, any reminders due, and weather. Note any scheduling conflicts or unusually long gaps.",
            intervalMinutes: 0
        ),
        ShortcutTemplate(
            id: "focus-timer",
            name: "Focus Session",
            icon: "timer",
            category: String(localized: "Productivity"),
            description: String(localized: "Starts a focus/pomodoro timer and silences notifications."),
            shortcutSteps: String(localized: "1. Set Focus Mode (Do Not Disturb)\n2. Start Timer (25 min)\n3. When done: Turn off DND\n4. Output 'Focus session complete'"),
            agentBehavior: String(localized: "Tells you when the focus session starts and ends. Can suggest a break after completion."),
            scheduleDescription: String(localized: "On demand only"),
            taskId: "shortcut-focus-timer",
            taskPrompt: "Run the Siri Shortcut 'Focus Session' to start a 25-minute focus timer. Announce that the focus session has started and you'll let them know when it's done.",
            intervalMinutes: 0
        ),

        // MARK: Health
        ShortcutTemplate(
            id: "health-summary",
            name: "Health Summary",
            icon: "heart",
            category: String(localized: "Health"),
            description: String(localized: "Reads step count, active calories, and exercise minutes from HealthKit."),
            shortcutSteps: String(localized: "1. Get Health Sample (Steps, Today)\n2. Get Health Sample (Active Calories)\n3. Get Health Sample (Exercise Minutes)\n4. Output as text"),
            agentBehavior: String(localized: "Presents a brief health update. Compares to daily goals if known from memory. Encourages if behind, congratulates if ahead."),
            scheduleDescription: String(localized: "Every 2 hours"),
            taskId: "shortcut-health-summary",
            taskPrompt: "Run the Siri Shortcut 'Health Summary' to get today's health data. Present steps, calories, and exercise minutes naturally. Compare to any goals you know about from memory. Only report if there's something noteworthy (close to goal, unusually low, etc.).",
            intervalMinutes: 120
        ),

        // MARK: Smart Home
        ShortcutTemplate(
            id: "home-status",
            name: "Home Status",
            icon: "house",
            category: String(localized: "Smart Home"),
            description: String(localized: "Checks if any doors/windows are open or lights left on."),
            shortcutSteps: String(localized: "1. Get Home accessories state\n2. Filter: doors open, lights on\n3. Output status text"),
            agentBehavior: String(localized: "Only alerts if something is unexpected — a door left open, lights on in empty rooms. Stays quiet if everything is normal."),
            scheduleDescription: String(localized: "Every 30 minutes"),
            taskId: "shortcut-home-status",
            taskPrompt: "Run the Siri Shortcut 'Home Status' to check smart home state. Only report if something needs attention — doors left open, lights on when they shouldn't be, unusual sensor readings. If everything looks normal, there's nothing to report.",
            intervalMinutes: 30
        ),

        // MARK: News & Information
        ShortcutTemplate(
            id: "news-briefing",
            name: "News Briefing",
            icon: "newspaper",
            category: String(localized: "Information"),
            description: String(localized: "Fetches top headlines from Apple News or RSS feeds."),
            shortcutSteps: String(localized: "1. Get Articles from Apple News\n2. Filter: Top 5 headlines\n3. Get Title + Source for each\n4. Output as text list"),
            agentBehavior: String(localized: "Summarizes the top stories in 2-3 sentences. Skips topics the user has indicated they're not interested in (from memory)."),
            scheduleDescription: String(localized: "Every 2 hours"),
            taskId: "shortcut-news-briefing",
            taskPrompt: "Run the Siri Shortcut 'News Briefing' for top headlines. Summarize the most important 2-3 stories in spoken format. Skip topics the user isn't interested in (check memory). If nothing noteworthy, there's nothing to report.",
            intervalMinutes: 120
        ),

        // MARK: Travel
        ShortcutTemplate(
            id: "commute-check",
            name: "Commute Check",
            icon: "car",
            category: String(localized: "Travel"),
            description: String(localized: "Checks travel time to work/home and alerts about delays."),
            shortcutSteps: String(localized: "1. Get Travel Time (Home → Work)\n2. Compare to normal duration\n3. Output time + any delays"),
            agentBehavior: String(localized: "Only alerts if the commute is significantly longer than usual (traffic, accidents). Stays quiet if normal."),
            scheduleDescription: String(localized: "Weekday mornings"),
            taskId: "shortcut-commute-check",
            taskPrompt: "Run the Siri Shortcut 'Commute Check' for current travel time. Only report if travel time is significantly longer than usual or there are notable delays. If the commute looks normal, there's nothing to report.",
            intervalMinutes: 0
        ),
    ]
}
