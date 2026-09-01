import Foundation

/// Caches Home Assistant entities and provides fuzzy matching.
/// Fetches all entities from HA REST API and keeps them in memory
/// so the LLM tool description can include real device names and
/// fuzzy matching can resolve user-spoken names to entity IDs.
actor HomeAssistantEntityCache {
    static let shared = HomeAssistantEntityCache()

    struct CachedEntity {
        let entityId: String
        let friendlyName: String
        let domain: String
        let state: String
    }

    private var entities: [CachedEntity] = []
    private var lastFetch: Date?
    private let staleness: TimeInterval = 300 // 5 min

    /// Refresh if stale or forced.
    func refreshIfNeeded(force: Bool = false) async {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < staleness, !entities.isEmpty {
            return
        }
        await fetchEntities()
    }

    /// Fetch all entities from HA REST API.
    private func fetchEntities() async {
        let baseURL = Config.homeAssistantURL
        let token = Config.homeAssistantToken
        guard !baseURL.isEmpty, !token.isEmpty,
              let url = URL(string: "\(baseURL)/api/states") else {
            PrivacyLog.homeBridge(.homeAssistant, .notConfigured)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                PrivacyLog.homeBridge(.homeAssistant, .catalogueFetchFailed,
                                      error: .http(status: code))
                return
            }
            guard let states = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                PrivacyLog.homeBridge(.homeAssistant, .catalogueParseFailed)
                return
            }

            entities = states.compactMap { entry in
                guard let entityId = entry["entity_id"] as? String else { return nil }
                let attrs = entry["attributes"] as? [String: Any]
                let friendly = attrs?["friendly_name"] as? String ?? entityId
                let state = entry["state"] as? String ?? "unknown"
                let domain = String(entityId.split(separator: ".").first ?? "")
                return CachedEntity(entityId: entityId, friendlyName: friendly, domain: domain, state: state)
            }
            lastFetch = Date()
            PrivacyLog.homeBridge(.homeAssistant, .catalogueRefreshed, count: entities.count)
        } catch {
            PrivacyLog.homeBridge(.homeAssistant, .catalogueFetchFailed,
                                  error: SafeErrorSummary(error))
        }
    }

    /// Get all cached entities, optionally filtered by domain.
    func allEntities(domain: String? = nil) -> [CachedEntity] {
        if let d = domain {
            return entities.filter { $0.domain == d }
        }
        return entities
    }

    /// Fuzzy match a user query against cached entities.
    /// Returns the best matching entity_id, or nil if no good match.
    func fuzzyMatch(_ query: String, preferDomain: String? = nil) -> String? {
        guard !entities.isEmpty else { return nil }

        let q = query.lowercased()
            .replacingOccurrences(of: "_", with: " ")

        // Exact entity_id match
        if let exact = entities.first(where: { $0.entityId == query }) {
            return exact.entityId
        }

        // Score each entity
        var scored: [(entity: CachedEntity, score: Double)] = entities.map { entity in
            let name = entity.friendlyName.lowercased()
            let eid = entity.entityId.lowercased().replacingOccurrences(of: "_", with: " ")

            var score = 0.0

            // Exact friendly name match
            if name == q { score += 10.0 }
            // Friendly name contains query
            else if name.contains(q) { score += 6.0 }
            // Query contains friendly name
            else if q.contains(name) { score += 4.0 }
            // Entity ID contains query
            else if eid.contains(q) { score += 3.0 }
            // Word overlap scoring
            else {
                let queryWords = Set(q.split(separator: " ").map(String.init))
                let nameWords = Set(name.split(separator: " ").map(String.init))
                let overlap = queryWords.intersection(nameWords)
                if !overlap.isEmpty {
                    score += Double(overlap.count) / Double(max(queryWords.count, 1)) * 5.0
                }
            }

            // Domain preference boost
            if let pref = preferDomain, entity.domain == pref {
                score += 1.5
            }

            return (entity, score)
        }

        scored.sort { $0.score > $1.score }

        guard let best = scored.first, best.score >= 2.0 else {
            return nil
        }

        PrivacyLog.homeEntityResolved(.fuzzy)
        return best.entity.entityId
    }

    /// Build a compact device summary for injection into the LLM system prompt.
    /// Groups by domain and lists friendly_name → entity_id.
    func deviceSummaryForPrompt() -> String? {
        guard !entities.isEmpty else { return nil }

        // Filter to controllable domains only
        let controllable = Set(["light", "switch", "fan", "cover", "climate",
                                "lock", "media_player", "scene", "automation",
                                "script", "vacuum", "humidifier", "water_heater"])

        let relevant = entities.filter { controllable.contains($0.domain) }
        guard !relevant.isEmpty else { return nil }

        // Group by domain
        var grouped: [String: [(String, String)]] = [:]
        for e in relevant {
            grouped[e.domain, default: []].append((e.friendlyName, e.entityId))
        }

        var lines: [String] = ["Your Home Assistant devices:"]
        for domain in grouped.keys.sorted() {
            let items = grouped[domain]!.sorted { $0.0 < $1.0 }
            let list = items.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
            lines.append("  \(domain): \(list)")
        }

        return lines.joined(separator: "\n")
    }

    /// Clear the cache (e.g. when settings change).
    func invalidate() {
        entities = []
        lastFetch = nil
    }
}
