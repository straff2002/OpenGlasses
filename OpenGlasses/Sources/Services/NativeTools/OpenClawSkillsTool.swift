import Foundation

/// Expands OpenClaw gateway usage: discover available skills, check status,
/// and invoke specific OpenClaw capabilities beyond the generic "execute" tool.
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

        guard Config.isOpenClawConfigured else {
            return "OpenClaw is not configured. Enable it in Settings and provide a gateway token."
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
        request.setValue("Bearer \(Config.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
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

        let endpoint = await bridge.resolveEndpoint()

        let normalized = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(normalized)/health") else {
            return "Invalid gateway URL."
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(Config.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Fall back to asking the gateway via chat
                return await askGatewayForSkills()
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let skills = json["skills"] as? [[String: Any]] {
                let skillList = skills.prefix(20).compactMap { skill -> String? in
                    guard let name = skill["name"] as? String else { return nil }
                    let desc = skill["description"] as? String ?? ""
                    return desc.isEmpty ? name : "\(name): \(desc)"
                }
                return "Available OpenClaw skills (\(skills.count) total): \(skillList.joined(separator: "; "))"
            }

            return await askGatewayForSkills()
        } catch {
            return await askGatewayForSkills()
        }
    }

    private func getSkillInfo(skillName: String) async -> String {
        guard !skillName.isEmpty else {
            return "Provide a skill_name to get details about."
        }

        guard let bridge = openClawBridge else {
            return "OpenClaw bridge not available."
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
}
