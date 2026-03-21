import Foundation

/// Home Assistant integration via REST API.
/// Control entities, run automations, and check states.
/// Requires HA URL and Long-Lived Access Token configured in Settings.
struct HomeAssistantTool: NativeTool {
    let name = "home_assistant"
    let description = "Control Home Assistant: turn on/off devices, run automations, check sensor states. Requires Home Assistant URL and token in Settings."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "call_service, get_state, list_entities, run_automation, or toggle"],
                "entity_id": ["type": "string", "description": "Entity ID (e.g. light.living_room, switch.fan, automation.morning)"],
                "service": ["type": "string", "description": "Service to call (e.g. turn_on, turn_off, toggle). For call_service action."],
                "domain": ["type": "string", "description": "Entity domain filter for list_entities (e.g. light, switch, sensor, automation)"],
            ],
            "required": ["action"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        guard !Config.homeAssistantURL.isEmpty else {
            return "Home Assistant not configured. Add your HA URL and access token in Settings → Services."
        }
        guard !Config.homeAssistantToken.isEmpty else {
            return "Home Assistant access token not set. Generate a Long-Lived Access Token in HA → Profile → Security."
        }

        let action = (args["action"] as? String ?? "").lowercased()
        let entityId = args["entity_id"] as? String ?? ""

        switch action {
        case "toggle":
            guard !entityId.isEmpty else { return "Which entity should I toggle?" }
            return await callService(domain: entityId.split(separator: ".").first.map(String.init) ?? "homeassistant",
                                     service: "toggle", entityId: entityId)

        case "call_service":
            let service = args["service"] as? String ?? "toggle"
            guard !entityId.isEmpty else { return "Which entity?" }
            let domain = entityId.split(separator: ".").first.map(String.init) ?? "homeassistant"
            return await callService(domain: domain, service: service, entityId: entityId)

        case "get_state":
            guard !entityId.isEmpty else { return "Which entity should I check?" }
            return await getState(entityId: entityId)

        case "list_entities", "list":
            let domain = args["domain"] as? String
            return await listEntities(domain: domain)

        case "run_automation":
            guard !entityId.isEmpty else { return "Which automation should I run?" }
            return await callService(domain: "automation", service: "trigger", entityId: entityId)

        default:
            return "Unknown action '\(action)'. Use: toggle, call_service, get_state, list_entities, or run_automation."
        }
    }

    // MARK: - API Calls

    private func callService(domain: String, service: String, entityId: String) async -> String {
        let url = "\(Config.homeAssistantURL)/api/services/\(domain)/\(service)"
        let body: [String: Any] = ["entity_id": entityId]

        do {
            let _ = try await haRequest(url: url, method: "POST", body: body)
            return "Done — \(service) on \(entityId.replacingOccurrences(of: "_", with: " "))."
        } catch {
            return "Home Assistant error: \(error.localizedDescription)"
        }
    }

    private func getState(entityId: String) async -> String {
        let url = "\(Config.homeAssistantURL)/api/states/\(entityId)"

        do {
            let data = try await haRequest(url: url, method: "GET")
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let state = json["state"] as? String ?? "unknown"
                let friendlyName = (json["attributes"] as? [String: Any])?["friendly_name"] as? String ?? entityId
                return "\(friendlyName) is \(state)."
            }
            return "Couldn't parse state for \(entityId)."
        } catch {
            return "Error getting state: \(error.localizedDescription)"
        }
    }

    private func listEntities(domain: String?) async -> String {
        let url = "\(Config.homeAssistantURL)/api/states"

        do {
            let data = try await haRequest(url: url, method: "GET")
            guard let states = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return "Couldn't parse entity list."
            }

            let filtered = domain != nil
                ? states.filter { ($0["entity_id"] as? String ?? "").hasPrefix("\(domain!).") }
                : states

            let names = filtered.prefix(20).compactMap { entity -> String? in
                let id = entity["entity_id"] as? String ?? ""
                let state = entity["state"] as? String ?? ""
                let friendly = (entity["attributes"] as? [String: Any])?["friendly_name"] as? String
                return "\(friendly ?? id): \(state)"
            }

            if names.isEmpty { return "No entities found\(domain != nil ? " for domain '\(domain!)'" : "")." }
            return "\(filtered.count) entities\(domain != nil ? " (\(domain!))" : ""): \(names.joined(separator: ". "))"
        } catch {
            return "Error listing entities: \(error.localizedDescription)"
        }
    }

    private func haRequest(url: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(Config.homeAssistantToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
