import Foundation
import CoreLocation

/// Spatial object memory: "Remember where I put my keys" → saves object + location + time.
/// "Where are my keys?" → retrieves with distance and directions.
struct ObjectMemoryTool: NativeTool {
    let name = "object_memory"
    let description = "Remember where physical objects are. Actions: 'save' (remember an object's location), 'find' (where is something?), 'list' (all remembered objects), 'forget' (remove an object)."

    let locationService: LocationService

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "save, find, list, or forget"],
                "object": ["type": "string", "description": "The object name (e.g. 'keys', 'wallet', 'car')"],
                "location_description": ["type": "string", "description": "Where the object is (e.g. 'kitchen counter', 'left jacket pocket'). For save only."],
            ],
            "required": ["action"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "list").lowercased()
        let objectName = (args["object"] as? String)?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "save", "remember", "put":
            guard let name = objectName, !name.isEmpty else {
                return "What object should I remember? Say something like: remember my keys are on the kitchen counter."
            }
            let locationDesc = (args["location_description"] as? String) ?? "here"
            let currentLoc = await MainActor.run { locationService.currentLocation }

            let entry = ObjectMemoryEntry(
                id: UUID().uuidString,
                objectName: name,
                locationDescription: locationDesc,
                latitude: currentLoc?.coordinate.latitude,
                longitude: currentLoc?.coordinate.longitude,
                savedAt: Date()
            )
            ObjectMemoryStore.shared.save(entry)
            return "Got it — I'll remember your \(name) is at \(locationDesc)."

        case "find", "where", "locate":
            guard let name = objectName, !name.isEmpty else {
                return "What are you looking for?"
            }
            guard let entry = ObjectMemoryStore.shared.find(name) else {
                return "I don't know where your \(name) is. I haven't been told to remember it."
            }

            let timeAgo = entry.timeAgoString
            var response = "Your \(entry.objectName) was at \(entry.locationDescription), \(timeAgo) ago."

            // Add distance if we have GPS for both
            if let savedLat = entry.latitude, let savedLng = entry.longitude,
               let current = await MainActor.run(body: { locationService.currentLocation }) {
                let savedLoc = CLLocation(latitude: savedLat, longitude: savedLng)
                let distance = current.distance(from: savedLoc)
                if distance < 50 {
                    response += " That's very close to where you are now."
                } else if distance < 500 {
                    response += " That's about \(Int(distance)) meters from here."
                } else {
                    let km = distance / 1000
                    response += " That's about \(String(format: "%.1f", km)) km from here."
                }
            }
            return response

        case "list":
            let entries = ObjectMemoryStore.shared.all()
            if entries.isEmpty {
                return "I'm not remembering any objects right now. Say something like: remember my car is in lot B."
            }
            let list = entries.map { "\($0.objectName) at \($0.locationDescription) (\($0.timeAgoString) ago)" }.joined(separator: ". ")
            return "I'm remembering \(entries.count) objects: \(list)"

        case "forget", "remove", "delete":
            guard let name = objectName, !name.isEmpty else {
                return "Which object should I forget?"
            }
            if ObjectMemoryStore.shared.delete(name) {
                return "Forgotten. I no longer remember where your \(name) is."
            }
            return "I wasn't remembering your \(name) anyway."

        default:
            return "Unknown action '\(action)'. Use: save, find, list, or forget."
        }
    }
}

// MARK: - Storage

struct ObjectMemoryEntry: Codable, Identifiable {
    let id: String
    let objectName: String
    let locationDescription: String
    let latitude: Double?
    let longitude: Double?
    let savedAt: Date

    var timeAgoString: String {
        let seconds = Int(Date().timeIntervalSince(savedAt))
        if seconds < 60 { return "\(seconds) seconds" }
        if seconds < 3600 { return "\(seconds / 60) minutes" }
        if seconds < 86400 { return "\(seconds / 3600) hours" }
        return "\(seconds / 86400) days"
    }
}

class ObjectMemoryStore {
    static let shared = ObjectMemoryStore()
    private let key = "objectMemory"

    func all() -> [ObjectMemoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([ObjectMemoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ entry: ObjectMemoryEntry) {
        var entries = all()
        entries.removeAll { $0.objectName == entry.objectName }
        entries.append(entry)
        persist(entries)
    }

    func find(_ objectName: String) -> ObjectMemoryEntry? {
        all().first { $0.objectName == objectName.lowercased() }
    }

    func delete(_ objectName: String) -> Bool {
        var entries = all()
        let before = entries.count
        entries.removeAll { $0.objectName == objectName.lowercased() }
        if entries.count < before {
            persist(entries)
            return true
        }
        return false
    }

    private func persist(_ entries: [ObjectMemoryEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
