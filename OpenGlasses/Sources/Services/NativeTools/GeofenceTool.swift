import Foundation
import CoreLocation
import UserNotifications

/// Location-based reminders using CLLocationManager region monitoring.
/// "Remind me when I get to the office" or safety zones that alert when leaving.
final class GeofenceTool: NativeTool, @unchecked Sendable {
    let name = "geofence"
    let description = "Create location-based reminders. 'Remind me when I get to [place]' triggers a spoken alert when you arrive at or leave a location. Also supports safety zones."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: 'create' (new geofence reminder), 'list' (show active), 'delete' (remove by name), 'clear' (remove all)"
            ],
            "name": [
                "type": "string",
                "description": "Label for this geofence (e.g. 'office', 'home', 'gym')"
            ],
            "latitude": [
                "type": "number",
                "description": "Latitude of the location"
            ],
            "longitude": [
                "type": "number",
                "description": "Longitude of the location"
            ],
            "radius": [
                "type": "number",
                "description": "Radius in meters (default: 100, max: 500)"
            ],
            "trigger": [
                "type": "string",
                "description": "When to alert: 'enter' (default), 'exit', 'both'"
            ],
            "message": [
                "type": "string",
                "description": "Message to speak when triggered (default: auto-generated)"
            ],
            "address": [
                "type": "string",
                "description": "Address to geocode (alternative to lat/lng). E.g. '123 Main St, City'"
            ]
        ],
        "required": ["action"]
    ]

    private let locationManager: CLLocationManager
    private let locationService: LocationService

    /// Callback to speak alerts via TTS
    var onAlert: ((String) -> Void)?

    /// Stored geofences
    private static let storageKey = "geofence_reminders"

    struct GeofenceReminder: Codable, Identifiable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let radius: Double
        let trigger: String // "enter", "exit", "both"
        let message: String
        let createdAt: Date
    }

    init(locationService: LocationService) {
        self.locationService = locationService
        self.locationManager = CLLocationManager()
    }

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action specified. Use 'create', 'list', 'delete', or 'clear'."
        }

        switch action.lowercased() {
        case "create":
            return await createGeofence(args: args)
        case "list":
            return listGeofences()
        case "delete":
            return deleteGeofence(args: args)
        case "clear":
            return clearAllGeofences()
        default:
            return "Unknown action '\(action)'. Use 'create', 'list', 'delete', or 'clear'."
        }
    }

    // MARK: - Create

    private func createGeofence(args: [String: Any]) async -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return "Please provide a name for this geofence reminder."
        }

        // Get coordinates — either from lat/lng args or by geocoding an address
        let latitude: Double
        let longitude: Double

        if let lat = args["latitude"] as? Double, let lng = args["longitude"] as? Double {
            latitude = lat
            longitude = lng
        } else if let address = args["address"] as? String, !address.isEmpty {
            // Geocode the address
            guard let location = await GeocodingHelper.geocodeAddress(address) else {
                return "Couldn't find coordinates for '\(address)'. Try providing latitude and longitude directly."
            }
            latitude = location.coordinate.latitude
            longitude = location.coordinate.longitude
        } else if let currentLoc = await MainActor.run(body: { locationService.currentLocation }) {
            // Use current location if no coordinates or address provided
            latitude = currentLoc.coordinate.latitude
            longitude = currentLoc.coordinate.longitude
        } else {
            return "No location provided. Specify an address, latitude/longitude, or ensure location services are active."
        }

        let radius = min(max(args["radius"] as? Double ?? 100, 10), 500)
        let trigger = (args["trigger"] as? String)?.lowercased() ?? "enter"
        let message = args["message"] as? String ?? "You've \(trigger == "exit" ? "left" : "arrived at") \(name)."

        // Check iOS region monitoring limit (20 regions max)
        var reminders = loadReminders()
        if reminders.count >= 19 { // Leave 1 slot buffer
            return "Maximum geofence limit reached (20). Delete some first with action='delete'."
        }

        let reminder = GeofenceReminder(
            id: UUID().uuidString,
            name: name,
            latitude: latitude,
            longitude: longitude,
            radius: radius,
            trigger: trigger,
            message: message,
            createdAt: Date()
        )

        reminders.append(reminder)
        saveReminders(reminders)

        // Register with CLLocationManager
        await MainActor.run {
            registerRegion(for: reminder)
        }

        let triggerDesc = trigger == "both" ? "enter or leave" : trigger
        return "Geofence '\(name)' created. I'll alert you when you \(triggerDesc) within \(Int(radius))m of that location."
    }

    // MARK: - List

    private func listGeofences() -> String {
        let reminders = loadReminders()
        if reminders.isEmpty {
            return "No active geofence reminders. Create one with 'remind me when I get to [place]'."
        }

        let list = reminders.map { r in
            let triggerText = r.trigger == "both" ? "enter/exit" : r.trigger
            return "• \(r.name) (\(triggerText), \(Int(r.radius))m radius)"
        }
        return "Active geofences (\(reminders.count)):\n\(list.joined(separator: "\n"))"
    }

    // MARK: - Delete

    private func deleteGeofence(args: [String: Any]) -> String {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return "Specify the name of the geofence to delete."
        }

        var reminders = loadReminders()
        let target = name.lowercased()
        guard let index = reminders.firstIndex(where: { $0.name.lowercased().contains(target) }) else {
            return "No geofence matching '\(name)'. Use action='list' to see active ones."
        }

        let removed = reminders.remove(at: index)
        saveReminders(reminders)

        // Unregister from CLLocationManager
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: removed.latitude, longitude: removed.longitude),
            radius: removed.radius,
            identifier: removed.id
        )
        locationManager.stopMonitoring(for: region)

        return "Geofence '\(removed.name)' deleted."
    }

    // MARK: - Clear

    private func clearAllGeofences() -> String {
        let reminders = loadReminders()
        for r in reminders {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: r.latitude, longitude: r.longitude),
                radius: r.radius,
                identifier: r.id
            )
            locationManager.stopMonitoring(for: region)
        }
        saveReminders([])
        return "All geofence reminders cleared."
    }

    // MARK: - Region Registration

    private func registerRegion(for reminder: GeofenceReminder) {
        let center = CLLocationCoordinate2D(latitude: reminder.latitude, longitude: reminder.longitude)
        let region = CLCircularRegion(center: center, radius: reminder.radius, identifier: reminder.id)

        switch reminder.trigger {
        case "enter":
            region.notifyOnEntry = true
            region.notifyOnExit = false
        case "exit":
            region.notifyOnEntry = false
            region.notifyOnExit = true
        default: // "both"
            region.notifyOnEntry = true
            region.notifyOnExit = true
        }

        locationManager.startMonitoring(for: region)
    }

    /// Re-register all saved geofences (call on app launch)
    func restoreGeofences() {
        let reminders = loadReminders()
        for reminder in reminders {
            registerRegion(for: reminder)
        }
        if !reminders.isEmpty {
            print("📍 Restored \(reminders.count) geofence(s)")
        }
    }

    /// Called by LocationService delegate when a region event fires
    func handleRegionEvent(region: CLRegion, didEnter: Bool) {
        let reminders = loadReminders()
        guard let reminder = reminders.first(where: { $0.id == region.identifier }) else { return }

        let action = didEnter ? "arrived at" : "left"
        let message = reminder.message.isEmpty ? "You've \(action) \(reminder.name)." : reminder.message

        print("📍 Geofence triggered: \(message)")
        onAlert?(message)

        // Send local notification as backup
        let content = UNMutableNotificationContent()
        content.title = "OpenGlasses"
        content.body = message
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "geofence-\(reminder.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    private func loadReminders() -> [GeofenceReminder] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let reminders = try? JSONDecoder().decode([GeofenceReminder].self, from: data) else {
            return []
        }
        return reminders
    }

    private func saveReminders(_ reminders: [GeofenceReminder]) {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
