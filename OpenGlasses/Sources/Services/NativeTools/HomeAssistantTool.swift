import Foundation

/// Home Assistant integration via REST API.
/// Three-layer entity resolution:
///   1. LLM picks from real device list (injected into system prompt)
///   2. Fuzzy matching catches near-misses against cached entities
///   3. HA Conversation API fallback — send natural language, let HA figure it out
struct HomeAssistantTool: NativeTool {
    let name = "home_assistant"
    let description = "Control Home Assistant: turn on/off devices, run automations, check sensor states. You can also use 'converse' action to send natural language commands directly to HA's voice assistant."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "call_service, get_state, list_entities, run_automation, toggle, or converse"],
                "entity_id": ["type": "string", "description": "Entity ID (e.g. light.living_room, switch.fan). Not needed for converse."],
                "service": ["type": "string", "description": "Service to call (e.g. turn_on, turn_off, toggle). For call_service action."],
                "domain": ["type": "string", "description": "Entity domain filter for list_entities (e.g. light, switch, sensor, automation)"],
                "text": ["type": "string", "description": "Natural language command for converse action (e.g. 'turn on the living room lights')"],
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

        // Refresh entity cache in background
        await HomeAssistantEntityCache.shared.refreshIfNeeded()

        let action = (args["action"] as? String ?? "").lowercased()
        let rawEntityId = args["entity_id"] as? String ?? ""

        // Resolve entity ID via fuzzy matching
        let entityId = await resolveEntityId(rawEntityId, action: action)

        switch action {
        case "converse":
            let text = args["text"] as? String ?? ""
            guard !text.isEmpty else { return "What should I tell Home Assistant?" }
            return await converse(text: text)

        case "toggle":
            guard !entityId.isEmpty else { return "Which entity should I toggle?" }
            return await callServiceWithFallback(
                domain: entityId.split(separator: ".").first.map(String.init) ?? "homeassistant",
                service: "toggle", entityId: entityId, naturalLanguage: "toggle \(friendlyDescription(entityId))")

        case "call_service":
            let service = args["service"] as? String ?? "toggle"
            guard !entityId.isEmpty else { return "Which entity?" }
            let domain = entityId.split(separator: ".").first.map(String.init) ?? "homeassistant"
            return await callServiceWithFallback(
                domain: domain, service: service, entityId: entityId,
                naturalLanguage: "\(service.replacingOccurrences(of: "_", with: " ")) \(friendlyDescription(entityId))")

        case "get_state":
            guard !entityId.isEmpty else { return "Which entity should I check?" }
            return await getState(entityId: entityId)

        case "list_entities", "list":
            let domain = args["domain"] as? String
            return await listEntities(domain: domain)

        case "run_automation":
            guard !entityId.isEmpty else { return "Which automation should I run?" }
            return await callServiceWithFallback(
                domain: "automation", service: "trigger", entityId: entityId,
                naturalLanguage: "run automation \(friendlyDescription(entityId))")

        default:
            return "Unknown action '\(action)'. Use: toggle, call_service, get_state, list_entities, run_automation, or converse."
        }
    }

    // MARK: - Entity Resolution

    private func resolveEntityId(_ raw: String, action: String) async -> String {
        guard !raw.isEmpty else { return "" }

        let cache = HomeAssistantEntityCache.shared
        let all = await cache.allEntities()

        if all.contains(where: { $0.entityId == raw }) {
            return raw
        }

        let preferDomain: String? = {
            if raw.contains(".") {
                return String(raw.split(separator: ".").first ?? "")
            }
            return nil
        }()

        if let matched = await cache.fuzzyMatch(raw, preferDomain: preferDomain) {
            // Entity ids name a room and a device in someone's house — regulated class. Hashing
            // would not anonymise a dictionary that small, so only the match kind is recorded.
            PrivacyLog.homeEntityResolved(.fuzzy)
            return matched
        }

        return raw
    }

    /// Convert entity_id to a human-readable description for conversation fallback.
    private func friendlyDescription(_ entityId: String) -> String {
        entityId
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: ".")
            .last
            .map(String.init) ?? entityId
    }

    // MARK: - Conversation API

    /// Send natural language to HA's Conversation API.
    /// HA's Assist pipeline handles intent matching and entity resolution.
    private func converse(text: String) async -> String {
        let url = "\(Config.homeAssistantURL)/api/conversation/process"
        let body: [String: Any] = ["text": text, "language": "en"]

        do {
            let data = try await haRequest(url: url, method: "POST", body: body)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let response = json["response"] as? [String: Any],
               let speech = response["speech"] as? [String: Any],
               let plain = speech["plain"] as? [String: Any],
               let reply = plain["speech"] as? String {
                // The command and the reply are both spoken content: sizes only.
                PrivacyLog.homeOperation(.converse, success: true, replyCharacters: reply.count)
                return reply
            }
            return "Home Assistant processed the command but gave no response."
        } catch {
            PrivacyLog.homeOperation(.converse, success: false)
            return "Home Assistant conversation error: \(error.localizedDescription)"
        }
    }

    // MARK: - API Calls with Fallback

    /// Try direct service call first; on failure, fall back to Conversation API.
    private func callServiceWithFallback(domain: String, service: String, entityId: String, naturalLanguage: String) async -> String {
        let result = await callService(domain: domain, service: service, entityId: entityId)

        // If direct call failed, try Conversation API
        if result.contains("error") || result.contains("Error") {
            PrivacyLog.homeFallback(.callService)
            let conversationResult = await converse(text: naturalLanguage)
            // If conversation API also failed, return the original error
            if conversationResult.contains("error") || conversationResult.contains("Error") {
                return result
            }
            return conversationResult
        }
        return result
    }

    private func callService(domain: String, service: String, entityId: String) async -> String {
        let url = "\(Config.homeAssistantURL)/api/services/\(domain)/\(service)"
        let body: [String: Any] = ["entity_id": entityId]

        do {
            let _ = try await haRequest(url: url, method: "POST", body: body)
            PrivacyLog.homeOperation(.callService, success: true)
            return "Done — \(service) on \(entityId.replacingOccurrences(of: "_", with: " "))."
        } catch {
            PrivacyLog.homeOperation(.callService, success: false)
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
        let cache = HomeAssistantEntityCache.shared
        let cached = await cache.allEntities(domain: domain)

        if !cached.isEmpty {
            let names = cached.prefix(30).map { "\($0.friendlyName) (\($0.entityId)): \($0.state)" }
            return "\(cached.count) entities\(domain != nil ? " (\(domain!))" : ""): \(names.joined(separator: ". "))"
        }

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

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            // The body is the home's own state — status class only.
            PrivacyLog.requestFailed(.homeAssistant, .http(status: httpResponse.statusCode))
            throw URLError(.badServerResponse)
        }
        return data
    }
}
