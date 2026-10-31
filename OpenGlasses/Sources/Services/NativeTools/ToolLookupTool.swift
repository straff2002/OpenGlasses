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

    let name = "lookup_tools"
    let description = """
        Get the full definitions of tools from your tool list. Only some tools have their full \
        definitions attached; before you call any other tool from the list, call this with its exact \
        name (up to 8 names at once). Its definition is attached from your next step, then call it.
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "names": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Exact tool names from the tool list, e.g. [\"set_timer\", \"smart_home\"].",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["names"],
    ]

    weak var toolRegistry: NativeToolRegistry?

    func execute(args: [String: Any]) async throws -> String {
        let requested = ToolExposurePolicy.requestedNames(args)
        guard !requested.isEmpty else {
            return "Give the exact names of the tools you need, from the tool list."
        }
        let declarations: [[String: Any]] = await MainActor.run {
            guard let registry = toolRegistry else { return [] }
            return Self.declarable(ToolDeclarations.nativeToolDeclarations(registry: registry)
                + ToolDeclarations.mcpToolDeclarations(mcpClient: registry.mcpClientSource?()),
                vaultOnly: VaultOnlyPolicy.jobIsSealed)
        }
        return Self.render(requested: requested, declarable: declarations)
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
