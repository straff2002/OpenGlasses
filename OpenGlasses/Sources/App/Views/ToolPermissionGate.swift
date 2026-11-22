import Foundation
import EventKit
import Contacts
import UserNotifications
import HealthKit

/// The system permission a tool needs the first time it is switched on.
///
/// Lifted out of `ToolsSettingsView` unchanged so the Everyday "Works with your
/// iPhone" surface asks in exactly the same way the full tool list does — two
/// screens offering the same switch must not differ in whether iOS gets asked.
enum ToolPermissionGate {
    /// Tools that require a system permission when enabled, and the name of the
    /// permission as the denial alert says it.
    static let permissionTools: [String: String] = [
        "calendar": "Calendar access",
        "reminder": "Reminders access",
        "lookup_contact": "Contacts access",
        "set_alarm": "Notification permission",
        "fitness_coach": "HealthKit access",
        "health_summary": "Apple Health access",
    ]

    /// The permission's name in the UI's language, for the denial alert. `permissionTools` keeps
    /// the English names as the record of which tools need a permission at all. A dictionary, not a
    /// `switch`, so the request switch below stays the one place a tool's `case` appears.
    static func permissionName(for toolName: String) -> String? {
        let localizedNames: [String: String] = [
            "calendar": String(localized: "Calendar access"),
            "reminder": String(localized: "Reminders access"),
            "lookup_contact": String(localized: "Contacts access"),
            "set_alarm": String(localized: "Notification permission"),
            "fitness_coach": String(localized: "HealthKit access"),
            "health_summary": String(localized: "Apple Health access"),
        ]
        return localizedNames[toolName] ?? permissionTools[toolName]
    }

    /// Request the appropriate system permission for a tool. Returns true if
    /// granted — and true for tools that need nothing, so callers can gate
    /// uniformly.
    static func requestPermission(for toolName: String) async -> Bool {
        switch toolName {
        case "calendar":
            let store = EKEventStore()
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        case "reminder":
            let store = EKEventStore()
            do {
                return try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        case "lookup_contact":
            let store = CNContactStore()
            do {
                return try await store.requestAccess(for: .contacts)
            } catch {
                return false
            }
        case "set_alarm":
            let center = UNUserNotificationCenter.current()
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return false
            }
        case "fitness_coach":
            // Exactly what the tool reads (past workouts and their active energy) and writes
            // (a finished workout and its energy); the sets are the tool's own, so the prompt
            // cannot ask for one thing while the tool uses another.
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            do {
                try await HKHealthStore().requestAuthorization(toShare: FitnessCoachingTool.healthKitShareTypes,
                                                               read: FitnessCoachingTool.healthKitReadTypes)
                return true
            } catch {
                return false
            }
        case "health_summary":
            // Read-only: heart rate, resting heart rate, sleep and steps. HealthKit never says
            // whether read access was granted, so "asked" is the most this can report.
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            do {
                try await HKHealthStore().requestAuthorization(toShare: [],
                                                               read: HealthKitSampleReader.readTypes)
                return true
            } catch {
                return false
            }
        case "ring":
            // Plan MZ: what the ring writes, asked for when a ring is paired. The set is the
            // writer's own, so the prompt cannot ask for one thing while the writer saves another.
            // No new read types: everything reads the ring back through health summaries.
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            do {
                try await HKHealthStore().requestAuthorization(toShare: RingHealthWriter.shareTypes, read: [])
                return true
            } catch {
                return false
            }
        default:
            return true
        }
    }
}
