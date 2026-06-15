import Foundation

/// Reports the user's vehicle / EV status — battery charge %, estimated range, charging
/// state, and plug status — by reading **Home Assistant** sensors. Works today with any
/// car or charger exposed to HA (Tesla, Wallbox, Easee, Ohme, Enode, etc.); iOS sandboxing
/// means we can't read a vendor app directly, so HA is the bridge. Entity IDs are
/// fuzzy-matched from the HA entity cache. (Explicit per-metric entity overrides in
/// Settings are a tracked follow-up for when fuzzy matching picks the wrong sensor.)
struct VehicleTool: NativeTool {
    let name = "vehicle_status"
    let description = "Get the user's vehicle / EV status: battery charge %, estimated range, whether it's charging, and plug status. Reads live from Home Assistant. Use for questions like 'what's my car's charge?', 'is the car plugged in?', 'how much range do I have?'."
    let parametersSchema: [String: Any] = ["type": "object", "properties": [:]]

    /// One resolved vehicle metric (friendly name + raw state).
    struct Reading: Equatable {
        let name: String
        let state: String
    }

    func execute(args: [String: Any]) async throws -> String {
        guard !Config.homeAssistantURL.isEmpty else {
            return "Vehicle status reads from Home Assistant, which isn't set up yet. Add your HA URL and token in Settings → Services, then make sure your car or charger is exposed to Home Assistant."
        }

        let cache = HomeAssistantEntityCache.shared
        await cache.refreshIfNeeded(force: true)
        let entities = await cache.allEntities()

        let battery  = await Self.resolve(["car battery", "vehicle battery", "state of charge", "battery level"], entities: entities, cache: cache)
        let range    = await Self.resolve(["car range", "vehicle range", "estimated range", "range"], entities: entities, cache: cache)
        let charging = await Self.resolve(["car charging", "charging", "charger status", "charge state"], entities: entities, cache: cache)
        let plugged  = await Self.resolve(["car plugged in", "vehicle plug", "charging cable", "cable connected"], entities: entities, cache: cache)

        return Self.summary(battery: battery, range: range, charging: charging, plugged: plugged)
    }

    /// Try each query in order; return the first entity that fuzzy-matches.
    private static func resolve(_ queries: [String], entities: [HomeAssistantEntityCache.CachedEntity], cache: HomeAssistantEntityCache) async -> Reading? {
        for query in queries {
            if let id = await cache.fuzzyMatch(query),
               let entity = entities.first(where: { $0.entityId == id }) {
                return Reading(name: entity.friendlyName, state: entity.state)
            }
        }
        return nil
    }

    /// Pure formatter — testable without Home Assistant.
    static func summary(battery: Reading?, range: Reading?, charging: Reading?, plugged: Reading?) -> String {
        var parts: [String] = []
        if let b = battery { parts.append("\(b.state)% charged") }
        if let r = range { parts.append("about \(r.state) range") }
        if let c = charging {
            parts.append(isOn(c.state, truthy: ["on", "charging", "true", "yes"]) ? "currently charging" : "not charging")
        }
        if let p = plugged {
            parts.append(isOn(p.state, truthy: ["on", "plugged", "plugged_in", "true", "yes", "connected"]) ? "plugged in" : "unplugged")
        }
        guard !parts.isEmpty else {
            return "I couldn't find any vehicle sensors in Home Assistant. Make sure your car or charger is exposed to HA (Tesla, Wallbox, Easee, Enode, etc.)."
        }
        let label = battery?.name ?? range?.name ?? "Your vehicle"
        return "\(label): \(parts.joined(separator: ", "))."
    }

    private static func isOn(_ state: String, truthy: [String]) -> Bool {
        truthy.contains(state.lowercased().trimmingCharacters(in: .whitespaces))
    }
}
