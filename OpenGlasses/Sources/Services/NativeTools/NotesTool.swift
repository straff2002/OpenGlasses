import Foundation

/// Stores and retrieves notes in UserDefaults. Two tools: save_note and list_notes.

/// Who wrote a saved note (Plan HQ P1 item 4). `save_note`'s text is whatever the model passed it,
/// so a note says it was written by the assistant; a reader (Spotlight, a list, an export) can show
/// that without guessing from where the note happens to be stored.
enum SavedNoteOrigin {
    static let assistant = "assistant"
}

private struct SavedNote: Codable {
    let title: String?
    let content: String
    let timestamp: Date
    /// `SavedNoteOrigin`. Optional so notes saved before the field existed decode unchanged.
    let origin: String?
}

private enum NotesStorage {
    static let key = "nativeTool_savedNotes"
    static let maxNotes = 50

    static func loadNotes() -> [SavedNote] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let notes = try? JSONDecoder().decode([SavedNote].self, from: data) else {
            return []
        }
        return notes
    }

    static func saveNotes(_ notes: [SavedNote]) {
        var trimmed = notes
        if trimmed.count > maxNotes {
            trimmed = Array(trimmed.suffix(maxNotes))
        }
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct SaveNoteTool: NativeTool {
    let name = "save_note"
    let description = "Save a note or reminder for the user. Stored locally on the device."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "content": [
                "type": "string",
                "description": "The note content to save"
            ],
            "title": [
                "type": "string",
                "description": "Optional title for the note"
            ]
        ],
        "required": ["content"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let content = args["content"] as? String, !content.isEmpty else {
            return "No content provided for the note."
        }

        let title = args["title"] as? String

        var notes = NotesStorage.loadNotes()
        let note = SavedNote(title: title, content: content, timestamp: Date(),
                             origin: SavedNoteOrigin.assistant)
        notes.append(note)
        NotesStorage.saveNotes(notes)

        let count = min(notes.count, NotesStorage.maxNotes)
        if let title {
            return "Saved note \"\(title)\". You have \(count) note\(count == 1 ? "" : "s") total."
        }
        return "Note saved. You have \(count) note\(count == 1 ? "" : "s") total."
    }
}

struct ListNotesTool: NativeTool {
    let name = "list_notes"
    let description = "List all saved notes."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let notes = NotesStorage.loadNotes()

        guard !notes.isEmpty else {
            return "You don't have any saved notes."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"

        var result = "You have \(notes.count) note\(notes.count == 1 ? "" : "s"): "
        let recentNotes = notes.suffix(10) // Show last 10
        let descriptions = recentNotes.map { note in
            let dateStr = formatter.string(from: note.timestamp)
            if let title = note.title {
                return "\(title) (\(dateStr)): \(note.content.prefix(60))"
            }
            return "(\(dateStr)) \(note.content.prefix(80))"
        }
        result += descriptions.joined(separator: ". ")

        if notes.count > 10 {
            result += ". Plus \(notes.count - 10) older notes."
        }

        return result
    }
}
