import Foundation

/// Expands OpenClaw gateway usage: discover available skills, check status,
/// and invoke specific OpenClaw capabilities beyond the generic "execute" tool.
///
/// Plan EH P1: skills are read through the gateway's own `skills.status` / `skills.search` /
/// `skills.detail` methods when its hello-ok catalog offers them; a gateway without them is
/// asked in words, as before, and says so.
struct OpenClawSkillsTool: NativeTool {
    let name = "openclaw_skills"
    let description = "Discover and manage OpenClaw skills. List available skills, check gateway status, or get info about a specific skill."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "Action: list_skills, skill_info, gateway_status, search_skills",
                "enum": ["list_skills", "skill_info", "gateway_status", "search_skills"]
            ],
            "skill_name": [
                "type": "string",
                "description": "Name of a specific skill to get info about"
            ],
            "query": [
                "type": "string",
                "description": "Search query to find relevant skills"
            ]
        ],
        "required": ["action"]
    ]

    weak var openClawBridge: OpenClawBridge?

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "No action specified."
        }

        // BK P0: the gateway is an agentic capability — needs Agent Mode on, not just configured.
        guard Config.isOpenClawConfigured else {
            return "OpenClaw is not configured. Enable it in Settings and provide a gateway token."
        }
        guard Config.agentModeEnabled else {
            return "Agent Mode is off, so the OpenClaw gateway is disabled. Turn on Agentic Features in Settings to use it."
        }

        switch action {
        case "list_skills":
            return await listSkills()
        case "skill_info":
            let skill = args["skill_name"] as? String ?? ""
            return await getSkillInfo(skillName: skill)
        case "gateway_status":
            return await checkGatewayStatus()
        case "search_skills":
            let query = args["query"] as? String ?? ""
            return await searchSkills(query: query)
        default:
            return "Unknown action: \(action)"
        }
    }

    // MARK: - Gateway Status

    private func checkGatewayStatus() async -> String {
        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
        }

        let endpoint = await bridge.resolveEndpoint()
        let connectionMode = Config.openClawConnectionMode.displayName

        let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(normalized)/health") else {
            return "Invalid gateway URL."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(await bridge.activeToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "Gateway unreachable."
            }

            if http.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    return "Gateway connected via \(connectionMode). Status: \(status)."
                }
                return "Gateway connected via \(connectionMode). Status: OK."
            } else {
                return "Gateway responded with HTTP \(http.statusCode). Connection mode: \(connectionMode)."
            }
        } catch {
            return "Gateway unreachable: \(error.localizedDescription). Connection mode: \(connectionMode)."
        }
    }

    // MARK: - Skills Discovery

    private func listSkills() async -> String {
        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
        }
        let request = GatewayRequestCatalog.skillsStatus()
        guard await bridge.supports(request.method),
              let payload = await successPayload(bridge, request) else {
            return await askGatewayForSkills()
        }
        let rows = Self.skillRows(from: payload)
        guard !rows.isEmpty else { return await askGatewayForSkills() }
        return "Available OpenClaw skills (\(rows.count) total): \(rows.prefix(20).joined(separator: "; "))"
    }

    private func getSkillInfo(skillName: String) async -> String {
        guard !skillName.isEmpty else {
            return "Provide a skill_name to get details about."
        }

        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
        }

        let request = GatewayRequestCatalog.skillsDetail(slug: skillName)
        if await bridge.supports(request.method),
           let payload = await successPayload(bridge, request),
           let skill = payload["skill"] as? [String: Any] {
            let title = skill["displayName"] as? String ?? skill["slug"] as? String ?? skillName
            let summary = skill["summary"] as? String ?? ""
            return summary.isEmpty ? "OpenClaw skill '\(title)' has no summary."
                                   : "OpenClaw skill '\(title)': \(summary)"
        }

        let result = await bridge.delegateTask(task: "What can you tell me about the '\(skillName)' skill? What does it do and how do I use it?")
        switch result {
        case .success(let info):
            return "OpenClaw skill info for '\(skillName)': \(info)"
        case .failure(let error):
            return "Couldn't get skill info: \(error)"
        }
    }

    private func searchSkills(query: String) async -> String {
        guard !query.isEmpty else {
            return "Provide a search query to find relevant skills."
        }

        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
        }

        let request = GatewayRequestCatalog.skillsSearch(query: query)
        if await bridge.supports(request.method),
           let payload = await successPayload(bridge, request) {
            let hits = (payload["results"] as? [[String: Any]] ?? []).compactMap { hit -> String? in
                guard let slug = hit["slug"] as? String, !slug.isEmpty else { return nil }
                let name = hit["displayName"] as? String ?? slug
                let summary = hit["summary"] as? String ?? ""
                return summary.isEmpty ? name : "\(name): \(summary)"
            }
            if !hits.isEmpty {
                return "OpenClaw skills matching '\(query)': \(hits.joined(separator: "; "))"
            }
            return "No OpenClaw skills matched '\(query)'."
        }

        let result = await bridge.delegateTask(task: "Which of your available skills or capabilities can help with: \(query)? List the most relevant ones.")
        switch result {
        case .success(let info):
            return "OpenClaw skills matching '\(query)': \(info)"
        case .failure(let error):
            return "Skill search failed: \(error)"
        }
    }

    /// Fallback: ask the gateway itself what skills it has
    private func askGatewayForSkills() async -> String {
        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
        }

        let result = await bridge.delegateTask(task: "List all your available skills, capabilities, and integrations. Give me a concise list.")
        switch result {
        case .success(let info):
            return "OpenClaw capabilities: \(info)"
        case .failure(let error):
            return "Couldn't list skills: \(error)"
        }
    }

    // MARK: - Helpers

    private func successPayload(_ bridge: OpenClawBridge, _ request: GatewayRequest) async -> [String: Any]? {
        guard let response = try? await bridge.agentRequest(method: request.method, params: request.params),
              response["ok"] as? Bool == true else { return nil }
        return response["payload"] as? [String: Any]
    }

    /// One `name: description` row per installed skill, tolerant of the status payload's
    /// container key (the gateway groups skills by agent and source).
    static func skillRows(from payload: [String: Any]) -> [String] {
        var items: [[String: Any]] = []
        for key in ["skills", "entries", "installed", "results"] {
            if let list = payload[key] as? [[String: Any]] { items.append(contentsOf: list) }
        }
        if items.isEmpty {
            for value in payload.values {
                if let list = value as? [[String: Any]], list.first?["name"] != nil || list.first?["slug"] != nil {
                    items.append(contentsOf: list)
                }
            }
        }
        return items.compactMap { skill in
            guard let name = (skill["name"] as? String) ?? (skill["slug"] as? String)
                ?? (skill["displayName"] as? String), !name.isEmpty else { return nil }
            let desc = (skill["description"] as? String) ?? (skill["summary"] as? String) ?? ""
            return desc.isEmpty ? name : "\(name): \(desc)"
        }
    }
}
