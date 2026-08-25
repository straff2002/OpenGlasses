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
    ]

    static func permissionName(for toolName: String) -> String? {
        permissionTools[toolName]
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
            let healthStore = HKHealthStore()
            guard HKHealthStore.isHealthDataAvailable() else { return false }
            let readTypes: Set<HKObjectType> = [
                HKObjectType.quantityType(forIdentifier: .stepCount)!,
                HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            ]
            do {
                try await healthStore.requestAuthorization(toShare: [], read: readTypes)
                return true
            } catch {
                return false
            }
        default:
            return true
        }
    }
}
