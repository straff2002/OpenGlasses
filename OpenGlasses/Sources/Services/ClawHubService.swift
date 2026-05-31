import Foundation

// MARK: - ClawHub API Models

/// A skill listing from ClawHub's public API.
/// The API returns `displayName` and `summary` — we map these to `name` and `description`.
struct ClawHubSkill: Codable, Identifiable {
    let slug: String

    /// The API sends `displayName`; decoded via CodingKeys.
    let name: String
    /// The API sends `summary`; decoded via CodingKeys.
    let description: String

    let version: String?
    let downloads: Int?
    let stars: Int?
    let owner: String?
    let updatedAt: Double?  // Unix timestamp (milliseconds)
    let score: Double?      // Search relevance score

    /// Frontmatter metadata parsed from the skill detail endpoint.
    var metadata: ClawHubSkillMetadata?

    var id: String { slug }

    /// Computed compatibility after checking against native tools.
    var compatibility: SkillCompatibility?

    enum CodingKeys: String, CodingKey {
        case slug
        case name = "displayName"
        case description = "summary"
        case version, downloads, stars, owner, updatedAt, score
    }
}

/// Parsed metadata from SKILL.md frontmatter.
struct ClawHubSkillMetadata: Codable {
    var requiredEnv: [String]?
    var requiredBins: [String]?
    var anyBins: [String]?
    var alwaysRequiresGateway: Bool?
    var emoji: String?
    var homepage: String?
    var os: [String]?
    var skillKey: String?
}

/// Compatibility assessment for running a skill on-device vs requiring OpenClaw.
enum SkillCompatibility: Codable {
    case compatible           // Runs fully on-device with native tools
    case partiallyCompatible  // Some features need OpenClaw
    case openclawRequired     // Needs shell/bins/server-side APIs

    var label: String {
        switch self {
        case .compatible: return "Works on device"
        case .partiallyCompatible: return "Partial — some features need OpenClaw"
        case .openclawRequired: return "Requires OpenClaw"
        }
    }

    var icon: String {
        switch self {
        case .compatible: return "checkmark.circle.fill"
        case .partiallyCompatible: return "exclamationmark.circle.fill"
        case .openclawRequired: return "server.rack"
        }
    }

    var badgeColor: String {
        switch self {
        case .compatible: return "green"
        case .partiallyCompatible: return "orange"
        case .openclawRequired: return "purple"
        }
    }
}

/// Search/browse response wrapper — handles all known API response shapes.
struct ClawHubSearchResponse: Codable {
    let skills: [ClawHubSkill]?
    let results: [ClawHubSkill]?
    let items: [ClawHubSkill]?
    let total: Int?
    let nextCursor: String?

    var allSkills: [ClawHubSkill] {
        results ?? skills ?? items ?? []
    }
}

/// Detail endpoint response wrapper: `{"skill": {..., "stats": {...}}}`.
struct ClawHubSkillDetailResponse: Codable {
    let skill: ClawHubSkillDetailInner

    struct ClawHubSkillDetailInner: Codable {
        let slug: String
        let displayName: String
        let summary: String
        let tags: [String: String]?
        let stats: ClawHubSkillStats?
        let createdAt: Double?
        let updatedAt: Double?
    }

    struct ClawHubSkillStats: Codable {
        let downloads: Int?
        let stars: Int?
        let installsAllTime: Int?
        let installsCurrent: Int?
        let versions: Int?
    }

    var asClawHubSkill: ClawHubSkill {
        ClawHubSkill(
            slug: skill.slug,
            name: skill.displayName,
            description: skill.summary,
            version: skill.tags?["latest"],
            downloads: skill.stats?.downloads,
            stars: skill.stats?.stars,
            owner: nil,
            updatedAt: skill.updatedAt,
            score: nil
        )
    }
}

// MARK: - ClawHub API Client

/// Fetches skills from the ClawHub public API. No authentication required for browsing/downloading.
actor ClawHubService {
    static let shared = ClawHubService()

    private let baseURL = "https://clawhub.ai/api/v1"
    private let session: URLSession
    private let decoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// Browse featured/popular skills.
    /// The `/skills` endpoint may be empty, so we fall back to a curated search.
    func browse(sort: String = "trending", limit: Int = 30, offset: Int = 0) async throws -> [ClawHubSkill] {
        // Try the browse endpoint first
        let url = URL(string: "\(baseURL)/skills?sort=\(sort)&limit=\(limit)&offset=\(offset)")!
        let (data, response) = try await session.data(from: url)
        try checkResponse(response)

        let skills = decodeSkillList(from: data)
        if !skills.isEmpty {
            return skills
        }

        // Browse is empty — use curated search queries to populate the store
        NSLog("[ClawHub] Browse empty, falling back to curated searches")
        return try await fetchCuratedSkills(limit: limit)
    }

    /// Vector search for skills.
    func search(query: String, limit: Int = 20) async throws -> [ClawHubSkill] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "\(baseURL)/search?q=\(encoded)&limit=\(limit)")!
        let (data, response) = try await session.data(from: url)
        try checkResponse(response)
        return decodeSkillList(from: data)
    }

    /// Fetch skills from multiple curated search queries to populate the store.
    private func fetchCuratedSkills(limit: Int) async throws -> [ClawHubSkill] {
        let queries = [
            "weather forecast",
            "translate language",
            "writing assistant",
            "code programming",
            "research search",
            "productivity tools",
            "health fitness",
            "music audio",
            "image photo vision",
            "email communication",
        ]
        var seen = Set<String>()
        var all: [ClawHubSkill] = []

        // Fetch in parallel batches
        await withTaskGroup(of: [ClawHubSkill].self) { group in
            for query in queries {
                group.addTask { [self] in
                    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                    guard let url = URL(string: "\(self.baseURL)/search?q=\(encoded)&limit=5") else { return [] }
                    do {
                        let (data, response) = try await self.session.data(from: url)
                        try self.checkResponse(response)
                        return self.decodeSkillList(from: data)
                    } catch {
                        return []
                    }
                }
            }
            for await batch in group {
                for skill in batch {
                    if !seen.contains(skill.slug) {
                        seen.insert(skill.slug)
                        all.append(skill)
                    }
                }
            }
        }

        // Sort by score descending, limit
        return Array(all.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.prefix(limit))
    }

    /// Decode a skill list from any known response shape.
    private nonisolated func decodeSkillList(from data: Data) -> [ClawHubSkill] {
        // Try direct array
        if let skills = try? decoder.decode([ClawHubSkill].self, from: data), !skills.isEmpty {
            return skills
        }
        // Try wrapped response (results, skills, items)
        if let wrapped = try? decoder.decode(ClawHubSearchResponse.self, from: data) {
            return wrapped.allSkills
        }
        return []
    }

    /// Get full skill detail including metadata.
    func skillDetail(slug: String) async throws -> ClawHubSkill {
        let url = URL(string: "\(baseURL)/skills/\(slug)")!
        let (data, response) = try await session.data(from: url)
        try checkResponse(response)

        // The detail endpoint wraps: {"skill": {..., "stats": {...}}}
        var skill: ClawHubSkill
        if let wrapped = try? decoder.decode(ClawHubSkillDetailResponse.self, from: data) {
            skill = wrapped.asClawHubSkill
        } else {
            skill = try decoder.decode(ClawHubSkill.self, from: data)
        }

        // Parse metadata from the SKILL.md if not included in the response
        if skill.metadata == nil {
            skill.metadata = try? await fetchMetadata(slug: slug)
        }
        return skill
    }

    /// Read a file from a skill (usually SKILL.md).
    func readFile(slug: String, path: String = "SKILL.md") async throws -> String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let url = URL(string: "\(baseURL)/skills/\(slug)/file?path=\(encodedPath)")!
        let (data, response) = try await session.data(from: url)
        try checkResponse(response)

        // Response could be raw text or JSON-wrapped
        if let text = String(data: data, encoding: .utf8) {
            // If it starts with { it might be JSON-wrapped
            if text.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = json["content"] as? String {
                return content
            }
            return text
        }
        return ""
    }

    /// Download a skill's SKILL.md content for local installation.
    func downloadSkillContent(slug: String) async throws -> String {
        try await readFile(slug: slug, path: "SKILL.md")
    }

    // MARK: - Private

    private func fetchMetadata(slug: String) async throws -> ClawHubSkillMetadata {
        let content = try await readFile(slug: slug, path: "SKILL.md")
        return parseMetadata(from: content)
    }

    private nonisolated func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 429 {
            throw ClawHubError.rateLimited
        }
        if http.statusCode >= 400 {
            throw ClawHubError.httpError(http.statusCode)
        }
    }

    /// Parse YAML frontmatter from SKILL.md to extract requirements.
    nonisolated func parseMetadata(from content: String) -> ClawHubSkillMetadata {
        // Extract YAML frontmatter between --- markers
        let lines = content.components(separatedBy: "\n")
        guard let firstDash = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ClawHubSkillMetadata()
        }
        let afterFirst = lines.index(after: firstDash)
        guard let secondDash = lines[afterFirst...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ClawHubSkillMetadata()
        }

        let yamlLines = lines[afterFirst..<secondDash]
        let yaml = yamlLines.joined(separator: "\n")

        // Simple key extraction (not a full YAML parser, but handles common patterns)
        var metadata = ClawHubSkillMetadata()

        // Extract env requirements
        if let envMatch = extractYAMLArray(from: yaml, key: "env") {
            metadata.requiredEnv = envMatch
        }
        // Extract bin requirements
        if let binsMatch = extractYAMLArray(from: yaml, key: "bins") {
            metadata.requiredBins = binsMatch
        }
        if let anyBins = extractYAMLArray(from: yaml, key: "anyBins") {
            metadata.anyBins = anyBins
        }
        // Check always flag
        if yaml.contains("always: true") {
            metadata.alwaysRequiresGateway = true
        }
        // Extract emoji
        if let emoji = extractYAMLString(from: yaml, key: "emoji") {
            metadata.emoji = emoji
        }
        // Extract OS
        if let os = extractYAMLArray(from: yaml, key: "os") {
            metadata.os = os
        }

        return metadata
    }

    private nonisolated func extractYAMLArray(from yaml: String, key: String) -> [String]? {
        // Match both inline [a, b] and multiline - a\n- b formats
        let pattern = "\(key):\\s*\\[([^\\]]+)\\]"
        if let range = yaml.range(of: pattern, options: .regularExpression) {
            let match = yaml[range]
            if let bracket = match.range(of: "[") {
                let items = match[bracket.upperBound...]
                    .replacingOccurrences(of: "]", with: "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    .filter { !$0.isEmpty }
                return items.isEmpty ? nil : items
            }
        }

        // Multiline format
        let lines = yaml.components(separatedBy: "\n")
        if let keyLine = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) {
            var items: [String] = []
            for i in (keyLine + 1)..<lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("- ") {
                    let value = line.dropFirst(2).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    items.append(value)
                } else if !line.isEmpty {
                    break
                }
            }
            return items.isEmpty ? nil : items
        }
        return nil
    }

    private nonisolated func extractYAMLString(from yaml: String, key: String) -> String? {
        let pattern = "\(key):\\s*[\"']?([^\"'\\n]+)[\"']?"
        if let range = yaml.range(of: pattern, options: .regularExpression) {
            let match = String(yaml[range])
            let value = match.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

// MARK: - Errors

enum ClawHubError: LocalizedError {
    case rateLimited
    case httpError(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .rateLimited: return "Rate limited — try again in a moment"
        case .httpError(let code): return "Server error (\(code))"
        case .notFound: return "Skill not found"
        }
    }
}

// MARK: - Skill Compatibility Checker

/// Determines whether a ClawHub skill can run on-device with native tools
/// or requires an OpenClaw gateway.
struct SkillCompatibilityChecker {

    /// Native tool names available in the app.
    let nativeToolNames: Set<String>

    /// Check compatibility of a skill based on its metadata and content.
    func check(skill: ClawHubSkill, content: String) -> SkillCompatibility {
        let meta = skill.metadata ?? ClawHubSkillMetadata()

        // If the skill explicitly says it always needs the gateway
        if meta.alwaysRequiresGateway == true {
            return .openclawRequired
        }

        // If the skill requires binaries (shell commands), it needs OpenClaw
        let hasBins = !(meta.requiredBins ?? []).isEmpty
        if hasBins {
            return .openclawRequired
        }

        // If the skill requires env vars, check if we can satisfy them
        let requiredEnv = meta.requiredEnv ?? []
        let unsatisfiedEnv = requiredEnv.filter { !canSatisfyEnv($0) }
        if !unsatisfiedEnv.isEmpty {
            // Check if any native tools could handle the use case
            let contentLower = content.lowercased()
            let hasNativeOverlap = nativeToolNames.contains { tool in
                contentLower.contains(tool)
            }
            return hasNativeOverlap ? .partiallyCompatible : .openclawRequired
        }

        // Check if the skill content references capabilities we have natively
        let contentLower = content.lowercased()

        // Keywords that suggest shell/system access needed
        let shellKeywords = ["bash", "shell", "terminal", "subprocess", "exec(", "child_process",
                             "#!/bin", "curl ", "wget ", "pip install", "npm install", "brew install"]
        let needsShell = shellKeywords.contains { contentLower.contains($0) }
        if needsShell {
            return .openclawRequired
        }

        // OS restriction check
        if let os = meta.os, !os.isEmpty {
            let iosCompatible = os.contains("ios") || os.contains("all")
            let macOnly = os.allSatisfy { $0.contains("darwin") || $0.contains("macos") || $0.contains("linux") }
            if macOnly && !iosCompatible {
                return .openclawRequired
            }
        }

        return .compatible
    }

    /// Check if an environment variable requirement can be satisfied by the app.
    private func canSatisfyEnv(_ env: String) -> Bool {
        let envLower = env.lowercased()
        // Map common env vars to things the app already has
        let satisfiedPatterns = [
            "openai": Config.savedModels.contains { $0.provider == "openai" && !$0.apiKey.isEmpty },
            "anthropic": Config.savedModels.contains { $0.provider == "anthropic" && !$0.apiKey.isEmpty },
            "google": Config.savedModels.contains { $0.provider == "gemini" && !$0.apiKey.isEmpty },
            "gemini": Config.savedModels.contains { $0.provider == "gemini" && !$0.apiKey.isEmpty },
            "groq": Config.savedModels.contains { $0.provider == "groq" && !$0.apiKey.isEmpty },
            "perplexity": !Config.perplexityAPIKey.isEmpty,
            "eleven": !Config.elevenLabsAPIKey.isEmpty,
        ]

        for (pattern, satisfied) in satisfiedPatterns {
            if envLower.contains(pattern) && satisfied { return true }
        }
        return false
    }
}

// MARK: - Installed Skill Store

/// Manages locally installed ClawHub skills. Skills are stored as markdown files
/// and injected into the system prompt as additional context.
@MainActor
class InstalledSkillStore: ObservableObject {
    static let shared = InstalledSkillStore()

    @Published var installedSkills: [InstalledSkill] = []

    struct InstalledSkill: Codable, Identifiable {
        let slug: String
        let name: String
        let description: String
        let version: String
        var content: String
        var compatibility: SkillCompatibility
        let installedAt: Date
        var enabled: Bool

        var id: String { slug }
    }

    private let storageURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = docs.appendingPathComponent("clawhub_skills.json")
        load()
    }

    /// Install a skill from ClawHub.
    func install(skill: ClawHubSkill, content: String, compatibility: SkillCompatibility) {
        let installed = InstalledSkill(
            slug: skill.slug,
            name: skill.name,
            description: skill.description,
            version: skill.version ?? "0.0.0",
            content: content,
            compatibility: compatibility,
            installedAt: Date(),
            enabled: true
        )

        // Replace if already installed
        installedSkills.removeAll { $0.slug == skill.slug }
        installedSkills.append(installed)
        save()
        NSLog("[ClawHub] Installed skill: %@", skill.slug)
    }

    /// Uninstall a skill.
    func uninstall(slug: String) {
        installedSkills.removeAll { $0.slug == slug }
        save()
        NSLog("[ClawHub] Uninstalled skill: %@", slug)
    }

    /// Toggle a skill on/off without removing it.
    func setEnabled(_ slug: String, enabled: Bool) {
        if let idx = installedSkills.firstIndex(where: { $0.slug == slug }) {
            installedSkills[idx].enabled = enabled
            save()
        }
    }

    /// Check if a skill is installed.
    func isInstalled(_ slug: String) -> Bool {
        installedSkills.contains { $0.slug == slug }
    }

    // MARK: - Library export / import (Plan Q)

    /// Encode the full installed library to a versioned JSON envelope for sharing to another device.
    func exportLibraryData() throws -> Data {
        let envelope = SkillsLibraryEnvelope(items: installedSkills)
        return try SkillsLibraryIO.encoder().encode(envelope)
    }

    /// Decode an exported envelope without committing, so the caller can present a review/confirm step.
    /// Returns the skills as stored in the file (their on-file `enabled`/`compatibility` are ignored on
    /// commit — see `importLibrary`).
    func previewImport(_ data: Data) throws -> [InstalledSkill] {
        let envelope = try SkillsLibraryIO.decoder().decode(SkillsLibraryEnvelope<InstalledSkill>.self, from: data)
        return envelope.items
    }

    /// Merge an exported library by `slug`. Imported skills are **disabled by default** (never silently
    /// enabled — their `content` is injected straight into the system prompt) and their compatibility is
    /// **recomputed** against this device's tool set rather than trusted from the file. Returns the count
    /// merged.
    @discardableResult
    func importLibrary(_ data: Data) throws -> Int {
        let items = try previewImport(data)
        guard !items.isEmpty else { return 0 }

        let checker = SkillCompatibilityChecker(nativeToolNames: Set(installedSkills.map(\.slug)))
        for item in items {
            var probe = ClawHubSkill(
                slug: item.slug, name: item.name, description: item.description,
                version: item.version, downloads: nil, stars: nil, owner: nil, updatedAt: nil, score: nil
            )
            probe.metadata = ClawHubService.shared.parseMetadata(from: item.content)
            let compatibility = checker.check(skill: probe, content: item.content)

            let imported = InstalledSkill(
                slug: item.slug,
                name: item.name,
                description: item.description,
                version: item.version,
                content: item.content,
                compatibility: compatibility,
                installedAt: Date(),
                enabled: false   // review-and-enable; never auto-enable an imported prompt
            )
            installedSkills.removeAll { $0.slug == imported.slug }
            installedSkills.append(imported)
        }
        save()
        NSLog("[ClawHub] Imported %d skill(s) (disabled pending review)", items.count)
        return items.count
    }

    /// Generate prompt context from all enabled installed skills.
    func promptContext() -> String? {
        let enabled = installedSkills.filter(\.enabled)
        guard !enabled.isEmpty else { return nil }

        var context = "INSTALLED SKILLS (from ClawHub):\n"
        for skill in enabled {
            // Strip the YAML frontmatter, keep the markdown body
            let body = stripFrontmatter(skill.content)
            context += "\n--- \(skill.name) ---\n"
            context += body.trimmingCharacters(in: .whitespacesAndNewlines)
            context += "\n"
        }
        return context
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(installedSkills)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[ClawHub] Failed to save: %@", error.localizedDescription)
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            installedSkills = try JSONDecoder().decode([InstalledSkill].self, from: data)
        } catch {
            NSLog("[ClawHub] Failed to load: %@", error.localizedDescription)
        }
    }

    private func stripFrontmatter(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }
        let after = lines.index(after: first)
        guard let second = lines[after...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return content
        }
        return lines[(second + 1)...].joined(separator: "\n")
    }
}
