import Foundation

/// `lookup_tools` — returns the full definitions of named tools from the prompt's tool list
/// (Plan IU, on-demand tool schemas).
///
/// Declared only when a turn's exposure is `core` (`ToolExposurePolicy`): the request then carries
/// full schemas for a small everyday set, and the model looks up anything else before it calls it.
/// The names it returns are promoted by `LLMService` and declared in full from the next round.
///
/// It only ever answers with what the model could be declared right now — the very filter the
/// declarations themselves use (enabled, not HIPAA-disabled, inside the Field Assist profile during
/// a job; MCP tools only when offered, and nothing a vault-only job seals) — so a disabled tool's
/// schema can never leak through it. It is infrastructure, not a feature:
/// `NativeToolRegistry.toolNames` and `ToolDeclarations` leave it out of the full list, and the Tools
/// screen does not offer a switch for it.
struct ToolLookupTool: NativeTool {
    nonisolated static let toolName = "lookup_tools"
    /// How many definitions one call may return, so a "look up everything" call cannot rebuild
    /// the whole tools block inside a single tool result.
    static let maxNamesPerCall = 8
    /// How many tools a keyword `query` names (Plan LP §7).
    static let maxMatchesPerQuery = 5

    let name = "lookup_tools"
    let description = """
        Get the full definitions of tools from your tool list. Only some tools have their full \
        definitions attached; before you call any other tool from the list, call this with its exact \
        name (up to 8 names at once). Its definition is attached from your next step, then call it. \
        Not sure which tool does something? Pass a query of a word or two instead ("parking") to get \
        up to 5 matching names with one line each.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "names": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Exact tool names from the tool list, e.g. [\"set_timer\", \"smart_home\"].",
            ] as [String: Any],
            "query": [
                "type": "string",
                "description": "A word or two about what the tool should do, e.g. \"parking\", to find which tool does it.",
            ] as [String: Any],
        ] as [String: Any],
        "required": [] as [String],
    ]

    weak var toolRegistry: NativeToolRegistry?

    func execute(args: [String: Any]) async throws -> String {
        let requested = ToolExposurePolicy.requestedNames(args)
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !requested.isEmpty || !query.isEmpty else {
            return "Give the exact names of the tools you need, from the tool list, or a query of a word or two."
        }
        let (native, mcp): ([[String: Any]], [[String: Any]]) = await MainActor.run {
            guard let registry = toolRegistry else { return ([], []) }
            let sealed = VaultOnlyPolicy.jobIsSealed
            return (Self.declarable(ToolDeclarations.nativeToolDeclarations(registry: registry), vaultOnly: sealed),
                    Self.declarable(ToolDeclarations.mcpToolDeclarations(mcpClient: registry.mcpClientSource?()),
                                    vaultOnly: sealed))
        }
        var parts: [String] = []
        if !requested.isEmpty { parts.append(Self.render(requested: requested, declarable: native + mcp)) }
        if !query.isEmpty { parts.append(Self.renderMatches(query: query, native: native, mcp: mcp)) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Keyword lookup (Plan LP §7)

    /// Words in a "which tool…" question that say nothing about what the tool does.
    static let queryMetaWords: Set<String> = [
        "tool", "tools", "there", "any", "something", "anything", "can", "could", "would", "use",
        "help", "need", "want", "thing", "app", "function", "let", "lets", "have", "has",
    ]

    /// The query's topic words: recall's meta-word stripping, then the lookup's own.
    static func queryTerms(_ query: String) -> [String] {
        FTSQueryBuilder.searchTerms(in: query).terms.filter { !queryMetaWords.contains($0) }
    }

    /// The declarations a query matches, best first, at most `maxMatchesPerQuery`. A word in the
    /// tool's name counts more than one in its description; "parking" finds `find_parking`, and
    /// "park" finds "parking". Ties keep the order given. Pure.
    static func matches(query: String, in declarations: [[String: Any]]) -> [(name: String, line: String)] {
        let terms = queryTerms(query).map(stem)
        guard !terms.isEmpty else { return [] }
        var scored: [(index: Int, score: Int, name: String, line: String)] = []
        for (index, decl) in declarations.enumerated() {
            guard let name = decl["name"] as? String else { continue }
            let description = decl["description"] as? String ?? ""
            let nameWords = words(name)
            let descriptionWords = Set(words(description))
            var score = 0
            for term in terms {
                if nameWords.contains(where: { wordMatches($0, term) }) {
                    score += 3
                } else if descriptionWords.contains(where: { wordMatches($0, term) }) {
                    score += 1
                }
            }
            if score > 0 {
                scored.append((index, score, name, SystemPromptBuilder.summary(description)))
            }
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(maxMatchesPerQuery).map { ($0.name, $0.line) }
    }

    /// The reply to a keyword query. A connected server's descriptions are its own words, so they
    /// come back inside the untrusted-output envelope, as data — never as instructions, and never
    /// raised into the system prompt.
    static func renderMatches(query: String, native: [[String: Any]], mcp: [[String: Any]]) -> String {
        let found = matches(query: query, in: native + mcp)
        guard !found.isEmpty else {
            return "No tool in the list matches \"\(query)\". Read the tool list for the nearest one."
        }
        let mcpNames = Set(mcp.compactMap { $0["name"] as? String })
        let own = found.filter { !mcpNames.contains($0.name) }
        let servers = found.filter { mcpNames.contains($0.name) }
        var lines = ["Tools matching \"\(query)\" (call \(toolName) with a name to get its definition):"]
        lines += own.map { "- \($0.name): \($0.line)" }
        if !servers.isEmpty {
            lines.append("From connected servers:")
            lines.append(PromptInjectionPolicy.wrap(
                toolName: toolName,
                content: servers.map { "- \($0.name): \($0.line)" }.joined(separator: "\n")))
        }
        return lines.joined(separator: "\n")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }.map(stem)
    }

    /// A light stem, so "parking", "parked" and "parks" meet "park". Only ever drops an ending.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    private static func wordMatches(_ word: String, _ term: String) -> Bool {
        word == term || (term.count >= 4 && word.hasPrefix(term))
    }

    /// What may be looked up: on a vault-only job, nothing the seal shuts, so a sealed tool cannot be
    /// looked up back in (Plan KE). Pure.
    static func declarable(_ declarations: [[String: Any]], vaultOnly: Bool) -> [[String: Any]] {
        guard vaultOnly else { return declarations }
        return declarations.filter { ($0["name"] as? String).map { !VaultOnlyPolicy.isSealed(tool: $0) } ?? false }
    }

    /// The reply for `requested` names over the declarations that may be given right now. Pure:
    /// a name outside `declarable` gets no schema, only a line saying it is not available.
    static func render(requested: [String], declarable: [[String: Any]]) -> String {
        let byName = Dictionary(declarable.compactMap { decl in
            (decl["name"] as? String).map { ($0, decl) }
        }, uniquingKeysWith: { first, _ in first })
        let asked = Array(requested.prefix(maxNamesPerCall))
        var found: [[String: Any]] = []
        var missing: [String] = []
        for name in asked {
            if let decl = byName[name] { found.append(decl) } else { missing.append(name) }
        }
        var lines: [String] = []
        if !found.isEmpty {
            let data = (try? JSONSerialization.data(withJSONObject: found, options: [.sortedKeys])) ?? Data()
            lines.append("Definitions (attached in full from your next step — call the tool then):")
            lines.append(String(data: data, encoding: .utf8) ?? "[]")
        }
        if !missing.isEmpty {
            lines.append("Not available: \(missing.joined(separator: ", ")). Use only names from the tool list.")
        }
        if requested.count > asked.count {
            lines.append("Only the first \(maxNamesPerCall) names were looked up; ask again for the rest.")
        }
        return lines.joined(separator: "\n")
    }

    /// The names a reply gave definitions for — what `LLMService` promotes. Pure.
    static func returnedNames(requested: [String], declarable: Set<String>) -> [String] {
        Array(requested.prefix(maxNamesPerCall)).filter(declarable.contains)
    }
}
