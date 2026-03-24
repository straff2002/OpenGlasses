import Foundation
import EventKit
import UserNotifications
import UIKit

/// Background service that proactively checks calendar events and delivers
/// spoken alerts through the glasses. Runs on a repeating timer while the app is active.
///
/// Alerts the user:
/// - 10 minutes before a calendar event starts
/// - When an event is about to start (1 minute)
/// - Daily morning briefing reminder (configurable)
@MainActor
final class ProactiveAlertService: ObservableObject {
    @Published var isRunning = false
    @Published var lastAlert: String?

    private var checkTimer: Timer?
    private var alertedEventIds: Set<String> = []
    private let eventStore = EKEventStore()

    /// Callback to speak an alert through TTS
    var onAlert: ((String) -> Void)?

    /// Callback to auto-create a playbook from a calendar event's agenda/notes
    var onMeetingPlaybook: ((String, String, [String]) -> Void)?

    // MARK: - Configuration

    /// Minutes before event to send first alert
    private let earlyAlertMinutes: Int = 10
    /// Minutes before event to send "starting now" alert
    private let imminentAlertMinutes: Int = 1
    /// How often to check (seconds)
    private let checkInterval: TimeInterval = 30

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Check immediately, then on interval
        checkForAlerts()

        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForAlerts()
            }
        }

        NSLog("[ProactiveAlerts] Started — checking every %.0fs", checkInterval)
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        isRunning = false
        alertedEventIds.removeAll()
        NSLog("[ProactiveAlerts] Stopped")
    }

    // MARK: - Alert Checking

    private func checkForAlerts() {
        // Check calendar access
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }

        let now = Date()
        let lookAhead = Calendar.current.date(byAdding: .minute, value: earlyAlertMinutes + 1, to: now)!

        let predicate = eventStore.predicateForEvents(withStart: now, end: lookAhead, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        for event in events {
            let minutesUntil = Int(event.startDate.timeIntervalSince(now) / 60)
            let eventKey = event.eventIdentifier ?? UUID().uuidString

            // Imminent alert (0-1 minutes)
            let imminentKey = "\(eventKey)-imminent"
            if minutesUntil <= imminentAlertMinutes && minutesUntil >= 0 && !alertedEventIds.contains(imminentKey) {
                alertedEventIds.insert(imminentKey)
                let title = event.title ?? "Event"
                var alert = "\(title) is starting now"
                if let location = event.location, !location.isEmpty {
                    alert += " at \(location)"
                }
                alert += "."
                deliverAlert(alert)

                // Auto-create playbook from calendar event notes/agenda
                if let notes = event.notes, !notes.isEmpty {
                    let steps = parseAgendaSteps(from: notes)
                    if steps.count >= 2 {
                        onMeetingPlaybook?(title, notes, steps)
                        NSLog("[ProactiveAlerts] Auto-created playbook from '%@' agenda (%d steps)", title, steps.count)
                    }
                }
            }
            // Early alert (around 10 minutes)
            else {
                let earlyKey = "\(eventKey)-early"
                if minutesUntil <= earlyAlertMinutes && minutesUntil > imminentAlertMinutes && !alertedEventIds.contains(earlyKey) {
                    alertedEventIds.insert(earlyKey)
                    let title = event.title ?? "Event"
                    var alert = "Heads up: \(title) starts in \(minutesUntil) minute\(minutesUntil == 1 ? "" : "s")"
                    if let location = event.location, !location.isEmpty {
                        alert += " at \(location)"
                    }
                    alert += "."
                    deliverAlert(alert)
                }
            }
        }

        // Clean up old event IDs (keep last 100 max)
        if alertedEventIds.count > 100 {
            alertedEventIds = Set(Array(alertedEventIds).suffix(50))
        }
    }

    private func deliverAlert(_ message: String) {
        lastAlert = message
        NSLog("[ProactiveAlerts] %@", message)

        // Speak through TTS if callback is set
        onAlert?(message)

        // Also send a local notification in case the app is backgrounded
        let content = UNMutableNotificationContent()
        content.title = "OpenGlasses"
        content.body = message
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "proactive-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Agenda Parsing

    /// Parse bullet points, numbered items, or line-separated items from calendar notes into steps.
    private func parseAgendaSteps(from notes: String) -> [String] {
        let lines = notes.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.compactMap { line in
            // Strip common prefixes: "- ", "• ", "1. ", "1) ", "* "
            var cleaned = line
            if let match = cleaned.range(of: #"^[\-\•\*]\s+"#, options: .regularExpression) {
                cleaned = String(cleaned[match.upperBound...])
            } else if let match = cleaned.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                cleaned = String(cleaned[match.upperBound...])
            }
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    // MARK: - Cleanup

    deinit {
        checkTimer?.invalidate()
    }
}
