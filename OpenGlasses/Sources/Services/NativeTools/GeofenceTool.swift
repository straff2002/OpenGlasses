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

    /// The region-monitoring seam (BK P1): production routes through `LocationService`'s single
    /// `CLLocationManager`/delegate; tests inject a fake. Replaces the tool's own orphaned manager
    /// (which never set `.delegate`, so no region event could ever reach `handleRegionEvent`).
    private let regionMonitor: RegionMonitoring
    private let locationService: LocationService

    /// Callback to speak alerts via TTS, with an urgency for rate/prefix.
    var onAlert: ((String, TextToSpeechService.SpeechUrgency) -> Void)?

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

    init(locationService: LocationService, regionMonitor: RegionMonitoring? = nil) {
        self.locationService = locationService
        self.regionMonitor = regionMonitor ?? locationService
    }

    /// Wire the region-event callbacks and re-arm saved geofences (BK P1). Called by AppState once
    /// the tool is registered; safe to call again. Without this the delegate had no forwarder and
    /// `handleRegionEvent` was dead code.
    @MainActor
    func activate() {
        regionMonitor.onRegionEvent = { [weak self] region, didEnter in
            self?.handleRegionEvent(region: region, didEnter: didEnter)
        }
        regionMonitor.onBecameAuthorizedAlways = { [weak self] in
            self?.restoreGeofences()
        }
        restoreGeofences()
    }

    // MARK: - Armability (pure)

    /// Whether a new region can be armed right now, and why not (BK P1). Reliable geofencing needs
    /// **Always** authorization (When-In-Use only delivers while the app is foregrounded), the OS
    /// caps monitored regions at 20, and a device may not support region monitoring at all.
    enum Armability: Equatable {
        case ok
        case needsPermission   // notDetermined — request Always, arm on grant
        case denied            // denied/restricted/When-In-Use — can't deliver reliably
        case unavailable       // device can't monitor regions
        case atCapacity        // 20-region OS cap reached
    }

    static func armability(status: CLAuthorizationStatus, monitoringAvailable: Bool, monitoredCount: Int) -> Armability {
        guard monitoringAvailable else { return .unavailable }
        switch status {
        case .authorizedAlways:
            return monitoredCount >= 20 ? .atCapacity : .ok
        case .notDetermined:
            return .needsPermission
        case .authorizedWhenInUse, .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
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
            return await deleteGeofence(args: args)
        case "clear":
            return await clearAllGeofences()
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
        let triggerDesc = trigger == "both" ? "enter or leave" : trigger

        // Pre-flight the monitoring capability on the main actor (BK P1). Return an HONEST message
        // when it can't be armed, rather than the old unconditional "I'll alert you" success.
        return await MainActor.run {
            switch Self.armability(
                status: regionMonitor.regionAuthorizationStatus,
                monitoringAvailable: regionMonitor.regionMonitoringAvailable(),
                monitoredCount: regionMonitor.monitoredRegionCount
            ) {
            case .ok:
                persist(reminder)
                registerRegion(for: reminder)
                return "Geofence '\(name)' created. I'll alert you when you \(triggerDesc) within \(Int(radius))m of that location."
            case .needsPermission:
                persist(reminder)   // arms automatically once Always is granted (onBecameAuthorizedAlways)
                regionMonitor.requestAlwaysAuthorization()
                return "To alert you at '\(name)' I need \"Always\" location access. I've asked for it — grant Always and I'll start watching for it."
            case .denied:
                return "I can't set a location reminder for '\(name)' — geofence alerts need \"Always\" location access, which isn't granted. Enable it in Settings → OpenGlasses → Location."
            case .unavailable:
                return "This device can't monitor geofence regions, so I can't set a location reminder."
            case .atCapacity:
                return "You already have the maximum of 20 geofence reminders. Delete one first with action='delete'."
            }
        }
    }

    /// Append a reminder to the saved set.
    private func persist(_ reminder: GeofenceReminder) {
        var reminders = loadReminders()
        reminders.append(reminder)
        saveReminders(reminders)
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

    private func deleteGeofence(args: [String: Any]) async -> String {
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

        await MainActor.run { regionMonitor.stopMonitoringRegion(region(for: removed)) }
        return "Geofence '\(removed.name)' deleted."
    }

    // MARK: - Clear

    private func clearAllGeofences() async -> String {
        let reminders = loadReminders()
        await MainActor.run {
            for r in reminders { regionMonitor.stopMonitoringRegion(region(for: r)) }
        }
        saveReminders([])
        return "All geofence reminders cleared."
    }

    // MARK: - Region Registration

    /// The `CLCircularRegion` for a reminder (id-keyed so region events resolve back to it).
    private func region(for reminder: GeofenceReminder) -> CLCircularRegion {
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
        return region
    }

    @MainActor
    private func registerRegion(for reminder: GeofenceReminder) {
        regionMonitor.startMonitoringRegion(region(for: reminder))
    }

    /// Re-register all saved geofences (call on app launch / when Always is granted). Only arms
    /// when Always authorization is in place — otherwise the OS won't deliver events anyway.
    @MainActor
    func restoreGeofences() {
        guard regionMonitor.regionAuthorizationStatus == .authorizedAlways else { return }
        let reminders = loadReminders()
        for reminder in reminders { registerRegion(for: reminder) }
        if !reminders.isEmpty {
            PrivacyLog.location(.geofencesRestored, count: reminders.count)
        }
    }

    /// Called by LocationService delegate when a region event fires
    func handleRegionEvent(region: CLRegion, didEnter: Bool) {
        let reminders = loadReminders()
        guard let reminder = reminders.first(where: { $0.id == region.identifier }) else { return }

        let action = didEnter ? "arrived at" : "left"
        let message = reminder.message.isEmpty ? "You've \(action) \(reminder.name)." : reminder.message

        PrivacyLog.location(didEnter ? .geofenceEntered : .geofenceExited)
        onAlert?(message, .medium)

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
