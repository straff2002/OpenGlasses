import Foundation

/// Lets the agent read and edit soul.md, skills.md, and memory.md
/// for itself and other personas.
///
/// The orchestrator agent uses this to:
/// - Review its own configuration
/// - Improve its own soul/skills based on what works
/// - Configure other persona agents' documents
struct AgentDocumentTool: NativeTool {
    let name = "edit_agent_docs"
    let description = """
        Read and edit agent identity documents (soul.md, skills.md, memory.md). \
        Use this to review and improve your own configuration, or to set up \
        other persona agents. You can read any document, append to it, or \
        replace a specific section.

        Documents:
        - soul.md: Identity, personality, values, goals, communication style
        - skills.md: Capabilities, tool usage patterns, delegation rules
        - memory.md: Learned facts, preferences, context (auto-updated)
        """

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "description": "What to do: 'read', 'append', 'replace_section', 'list_personas'",
                "enum": ["read", "append", "replace_section", "list_personas"]
            ],
            "document": [
                "type": "string",
                "description": "Which document: 'soul', 'skills', or 'memory'",
                "enum": ["soul", "skills", "memory"]
            ],
            "content": [
                "type": "string",
                "description": "Content to append, or new section content for replace_section"
            ],
            "section_header": [
                "type": "string",
                "description": "For replace_section: the markdown ## header of the section to replace (e.g., '## Goals')"
            ],
            "persona_id": [
                "type": "string",
                "description": "Edit a specific persona's documents instead of the main agent's. Use list_personas to see available IDs."
            ]
        ],
        "required": ["action"]
    ]

    weak var agentDocs: AgentDocumentStore?

    func execute(args: [String: Any]) async throws -> String {
        guard let action = args["action"] as? String else {
            return "Specify an action: read, append, replace_section, list_personas"
        }

        // List available personas
        if action == "list_personas" {
            let personas = await MainActor.run { Config.enabledPersonas }
            if personas.isEmpty {
                return "No personas configured. You can only edit the main agent's documents."
            }
            var lines = ["Available personas:"]
            for p in personas {
                let model = await MainActor.run { Config.savedModels.first(where: { $0.id == p.modelId })?.name ?? "unknown" }
                let hasSoul = p.soulOverride != nil ? "has custom soul" : "uses default soul"
                lines.append("- [\(p.id)] \(p.name) (wake: \"\(p.wakePhrase)\", model: \(model), \(hasSoul))")
            }
            return lines.joined(separator: "\n")
        }

        guard let docName = args["document"] as? String,
              let docType = AgentDocumentStore.DocumentType(rawValue: docName) else {
            return "Specify a document: 'soul', 'skills', or 'memory'"
        }

        // Check if editing a persona's soul override
        if let personaId = args["persona_id"] as? String {
            return await handlePersonaEdit(action: action, personaId: personaId, docType: docType, args: args)
        }

        // Edit main agent's documents
        guard let store = await MainActor.run(body: { agentDocs }) else {
            return "Agent document store not available."
        }

        switch action {
        case "read":
            let content = await MainActor.run { store.content(for: docType) }
            return "## \(docType.filename)\n\n\(content)"

        case "append":
            guard let content = args["content"] as? String, !content.isEmpty else {
                return "Provide content to append."
            }
            await MainActor.run {
                let current = store.content(for: docType)
                store.save(docType, content: current + "\n\n" + content)
            }
            return "Appended to \(docType.filename)."

        case "replace_section":
            guard let header = args["section_header"] as? String, !header.isEmpty else {
                return "Provide section_header (e.g., '## Goals') to identify the section to replace."
            }
            guard let newContent = args["content"] as? String, !newContent.isEmpty else {
                return "Provide the new content for the section."
            }
            let result = await MainActor.run { () -> String in
                let current = store.content(for: docType)
                guard let updated = replaceSection(in: current, header: header, newContent: newContent) else {
                    return "Section '\(header)' not found in \(docType.filename)."
                }
                store.save(docType, content: updated)
                return "Replaced section '\(header)' in \(docType.filename)."
            }
            return result

        default:
            return "Unknown action. Use: read, append, replace_section, list_personas"
        }
    }

    // MARK: - Persona Editing

    private func handlePersonaEdit(action: String, personaId: String, docType: AgentDocumentStore.DocumentType, args: [String: Any]) async -> String {
        // Only soul override is editable per-persona (skills/memory are shared)
        guard docType == .soul else {
            return "Only soul.md can be customized per persona. Skills and memory are shared across all personas."
        }

        let personas = await MainActor.run { Config.savedPersonas }
        guard let idx = personas.firstIndex(where: { $0.id == personaId }) else {
            return "Persona '\(personaId)' not found. Use list_personas to see available IDs."
        }

        switch action {
        case "read":
            let soul = personas[idx].soulOverride ?? "(using default soul — no custom override)"
            return "## \(personas[idx].name) soul.md\n\n\(soul)"

        case "append":
            guard let content = args["content"] as? String else { return "Provide content." }
            let current = personas[idx].soulOverride ?? ""
            var updated = personas
            updated[idx].soulOverride = current + "\n\n" + content
            let saved = updated
            await MainActor.run { Config.setSavedPersonas(saved) }
            return "Appended to \(personas[idx].name)'s soul."

        case "replace_section":
            guard let header = args["section_header"] as? String,
                  let content = args["content"] as? String else {
                return "Provide section_header and content."
            }
            guard let current = personas[idx].soulOverride else {
                return "\(personas[idx].name) has no custom soul yet. Use append to create one."
            }
            guard let replaced = replaceSection(in: current, header: header, newContent: content) else {
                return "Section '\(header)' not found in \(personas[idx].name)'s soul."
            }
            var updated = personas
            updated[idx].soulOverride = replaced
            let saved = updated
            await MainActor.run { Config.setSavedPersonas(saved) }
            return "Replaced '\(header)' in \(personas[idx].name)'s soul."

        default:
            return "Unknown action."
        }
    }

    // MARK: - Helpers

    /// Replace a markdown section (## Header ... next ## or end of file) with new content.
    private func replaceSection(in text: String, header: String, newContent: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let headerLine = header.trimmingCharacters(in: .whitespaces)

        // Find the section start
        guard let startIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == headerLine }) else {
            return nil
        }

        // Find the section end (next ## header or end of file)
        let level = headerLine.prefix(while: { $0 == "#" }).count
        var endIdx = lines.count
        for i in (startIdx + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(String(repeating: "#", count: level) + " ") && !trimmed.hasPrefix(String(repeating: "#", count: level + 1)) {
                endIdx = i
                break
            }
        }

        // Replace
        var newLines = Array(lines[0..<startIdx])
        newLines.append(headerLine)
        newLines.append(newContent)
        if endIdx < lines.count {
            newLines.append(contentsOf: lines[endIdx...])
        }

        return newLines.joined(separator: "\n")
    }
}
