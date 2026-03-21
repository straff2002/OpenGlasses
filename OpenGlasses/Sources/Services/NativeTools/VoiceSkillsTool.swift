import Foundation

/// Voice-taught skills: users teach the AI trigger→action patterns via natural language.
/// "Learn that when I say 'expense this', create a note tagged [EXPENSE]"
/// Skills persist across sessions and are injected into the system prompt.
struct VoiceSkillsTool: NativeTool {
    let name = "voice_skills"
    let description = "Manage voice-taught skills. Actions: 'save' (teach a new skill), 'list' (show all skills), 'delete' (remove a skill), 'clear' (remove all)."

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "save, list, delete, or clear"],
                "trigger": ["type": "string", "description": "The phrase that activates this skill (for save/delete)"],
                "instruction": ["type": "string", "description": "What to do when the trigger is said (for save)"],
            ],
            "required": ["action"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "list").lowercased()

        switch action {
        case "save", "learn", "teach":
            guard let trigger = args["trigger"] as? String, !trigger.isEmpty else {
                return "I need a trigger phrase. Say something like: learn that when I say 'expense this', create a note tagged EXPENSE."
            }
            guard let instruction = args["instruction"] as? String, !instruction.isEmpty else {
                return "I need an instruction for what to do. What should happen when you say '\(trigger)'?"
            }
            let skill = VoiceSkill(
                id: UUID().uuidString,
                trigger: trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                instruction: instruction.trimmingCharacters(in: .whitespacesAndNewlines),
                createdAt: Date()
            )
            VoiceSkillStore.shared.save(skill)
            return "Learned: when you say '\(skill.trigger)', I'll \(skill.instruction). You can say 'list skills' to see all, or 'forget \(skill.trigger)' to remove it."

        case "list":
            let skills = VoiceSkillStore.shared.all()
            if skills.isEmpty {
                return "No skills learned yet. Teach me by saying something like: learn that when I say 'goodnight', turn off all lights."
            }
            let list = skills.enumerated().map { i, s in "\(i + 1). \"\(s.trigger)\" → \(s.instruction)" }.joined(separator: ". ")
            return "You've taught me \(skills.count) skill\(skills.count == 1 ? "" : "s"): \(list)"

        case "delete", "forget", "remove":
            guard let trigger = args["trigger"] as? String, !trigger.isEmpty else {
                return "Which skill should I forget? Tell me the trigger phrase."
            }
            if VoiceSkillStore.shared.delete(trigger: trigger.lowercased()) {
                return "Forgotten: I'll no longer respond to '\(trigger)' as a skill."
            } else {
                return "I don't have a skill for '\(trigger)'. Say 'list skills' to see what I know."
            }

        case "clear":
            let count = VoiceSkillStore.shared.all().count
            VoiceSkillStore.shared.clearAll()
            return "Cleared all \(count) learned skills."

        default:
            return "Unknown action '\(action)'. Use: save, list, delete, or clear."
        }
    }
}

// MARK: - Skill Storage

struct VoiceSkill: Codable, Identifiable {
    let id: String
    let trigger: String
    let instruction: String
    let createdAt: Date
}

class VoiceSkillStore {
    static let shared = VoiceSkillStore()
    private let key = "voiceSkills"

    func all() -> [VoiceSkill] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let skills = try? JSONDecoder().decode([VoiceSkill].self, from: data) else {
            return []
        }
        return skills
    }

    func save(_ skill: VoiceSkill) {
        var skills = all()
        // Replace if trigger already exists
        skills.removeAll { $0.trigger == skill.trigger }
        skills.append(skill)
        persist(skills)
    }

    func delete(trigger: String) -> Bool {
        var skills = all()
        let before = skills.count
        skills.removeAll { $0.trigger == trigger }
        if skills.count < before {
            persist(skills)
            return true
        }
        return false
    }

    func clearAll() {
        persist([])
    }

    /// Generate the [LEARNED_SKILLS] prompt block for injection into the system prompt.
    func promptContext() -> String? {
        let skills = all()
        guard !skills.isEmpty else { return nil }
        var block = "\nLEARNED SKILLS (voice-taught by the user — apply automatically when trigger is detected):"
        for skill in skills {
            block += "\n- When user says \"\(skill.trigger)\": \(skill.instruction)"
        }
        return block
    }

    private func persist(_ skills: [VoiceSkill]) {
        if let data = try? JSONEncoder().encode(skills) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
