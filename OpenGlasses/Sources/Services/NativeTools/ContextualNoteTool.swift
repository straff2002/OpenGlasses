import Foundation

/// Contextual notes: saves notes auto-tagged with location, time, and optional camera context.
/// "Note: this restaurant has great ramen" → saves with GPS, timestamp, and place name.
struct ContextualNoteTool: NativeTool {
    let name = "contextual_note"
    let description = "Save a note with automatic location and time context. Actions: 'save' (create tagged note), 'search' (find notes by keyword or location), 'list' (recent notes), 'delete' (remove a note)."

    let locationService: LocationService

    var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "action": ["type": "string", "description": "save, search, list, or delete"],
                "content": ["type": "string", "description": "The note text (for save)"],
                "tags": ["type": "string", "description": "Comma-separated tags (for save, optional)"],
                "query": ["type": "string", "description": "Search keyword (for search)"],
            ],
            "required": ["action"],
        ]
    }

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String ?? "list").lowercased()

        switch action {
        case "save", "note", "remember":
            guard let content = args["content"] as? String, !content.isEmpty else {
                return "What should I note down?"
            }
            let tagsString = args["tags"] as? String ?? ""
            let tags = tagsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let currentLoc = await MainActor.run { locationService.currentLocation }
            let locationContext = await MainActor.run { locationService.locationContext }

            let note = ContextualNote(
                id: UUID().uuidString,
                content: content,
                tags: tags,
                latitude: currentLoc?.coordinate.latitude,
                longitude: currentLoc?.coordinate.longitude,
                locationName: locationContext,
                createdAt: Date()
            )
            ContextualNoteStore.shared.save(note)

            var response = "Noted"
            if let loc = locationContext {
                response += " at \(loc)"
            }
            if !tags.isEmpty {
                response += " (tagged: \(tags.joined(separator: ", ")))"
            }
            return response + "."

        case "search", "find":
            let query = (args["query"] as? String ?? "").lowercased()
            if query.isEmpty {
                return "What should I search for in your notes?"
            }
            let results = ContextualNoteStore.shared.search(query)
            if results.isEmpty {
                return "No notes found matching '\(query)'."
            }
            let list = results.prefix(5).map { note in
                var desc = note.content.prefix(60)
                if let loc = note.locationName { desc += " (at \(loc))" }
                desc += " — \(note.timeAgoString) ago"
                return String(desc)
            }.joined(separator: ". ")
            return "Found \(results.count) notes: \(list)"

        case "list", "recent":
            let notes = ContextualNoteStore.shared.recent(10)
            if notes.isEmpty {
                return "No contextual notes saved yet."
            }
            let list = notes.prefix(5).map { note in
                var desc = "\(note.content.prefix(40))"
                if let loc = note.locationName { desc += " (at \(loc))" }
                desc += " — \(note.timeAgoString) ago"
                return desc
            }.joined(separator: ". ")
            return "\(notes.count) recent notes: \(list)"

        case "delete":
            let query = args["query"] as? String ?? args["content"] as? String ?? ""
            if query.isEmpty {
                return "Which note should I delete? Give me a keyword."
            }
            let deleted = ContextualNoteStore.shared.deleteMatching(query.lowercased())
            return deleted > 0 ? "Deleted \(deleted) note(s) matching '\(query)'." : "No notes found matching '\(query)'."

        default:
            return "Unknown action. Use: save, search, list, or delete."
        }
    }
}

// MARK: - Storage

struct ContextualNote: Codable, Identifiable {
    let id: String
    let content: String
    let tags: [String]
    let latitude: Double?
    let longitude: Double?
    let locationName: String?
    let createdAt: Date

    var timeAgoString: String {
        let seconds = Int(Date().timeIntervalSince(createdAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

class ContextualNoteStore {
    static let shared = ContextualNoteStore()
    private let key = "contextualNotes"

    func all() -> [ContextualNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([ContextualNote].self, from: data) else { return [] }
        return notes
    }

    func save(_ note: ContextualNote) {
        var notes = all()
        notes.append(note)
        persist(notes)
    }

    func recent(_ count: Int) -> [ContextualNote] {
        Array(all().sorted { $0.createdAt > $1.createdAt }.prefix(count))
    }

    func search(_ query: String) -> [ContextualNote] {
        let q = query.lowercased()
        return all().filter { note in
            note.content.lowercased().contains(q) ||
            note.tags.contains(where: { $0.contains(q) }) ||
            (note.locationName?.lowercased().contains(q) ?? false)
        }
    }

    func deleteMatching(_ query: String) -> Int {
        var notes = all()
        let before = notes.count
        notes.removeAll { $0.content.lowercased().contains(query) || $0.tags.contains(query) }
        persist(notes)
        return before - notes.count
    }

    private func persist(_ notes: [ContextualNote]) {
        if let data = try? JSONEncoder().encode(notes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
