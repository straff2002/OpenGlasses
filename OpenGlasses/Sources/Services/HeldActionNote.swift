import Foundation

/// What a reply says about the actions its turn asked for that did not run and wait on the wearer
/// — held while they were away, or never asked about because another approval was on screen.
///
/// Field report: the assistant offered to run a Shortcut, the call was held, and nothing more was
/// said. Asked later "what was the shortcut you were gonna run", the model could only answer that
/// `run_shortcut` was an internal label: a finished turn keeps none of its tool calls (the
/// Responses items are stripped when it ends, and a reloaded thread is words only), so the
/// Shortcut's name had gone with them.
///
/// So the held actions travel with the saved reply (`ConversationMessage.heldActions`): the thread
/// shows them under it, in the wearer's language, and the model is given them with the reply's
/// words, in English, both in the live history and when a thread is replayed.
enum HeldActionNote {

    // MARK: - For the model (English)

    /// The note the model reads after the reply, or nil when nothing was held.
    static func modelNote(_ held: [String]) -> String? {
        let items = cleaned(held)
        guard !items.isEmpty else { return nil }
        let list = items.joined(separator: "; ")
        return "[Note from the app: this turn asked for something that was held and has NOT run: \(list). If the user asks about it, name it exactly. It runs only if the user asks for it again and approves it.]"
    }

    /// A saved reply's words as the model is given them on replay: the words, then the note.
    static func replayed(_ content: String, held: [String]) -> String {
        guard let note = modelNote(held) else { return content }
        return content.isEmpty ? note : content + "\n\n" + note
    }

    /// The live history with the note added to the last assistant message — the reply just given.
    /// The message's own shape is kept: a string gets the note appended, a list of blocks gets it
    /// appended to its last text block (`content` or Gemini's `parts`). Unchanged when nothing was
    /// held or there is no assistant message to add it to.
    static func appendingToLastAssistant(_ history: [[String: Any]], held: [String]) -> [[String: Any]] {
        guard let note = modelNote(held),
              let index = history.lastIndex(where: { $0["role"] as? String == "assistant" }) else {
            return history
        }
        var history = history
        var message = history[index]
        if let content = message["content"] as? String {
            message["content"] = replayed(content, held: held)
        } else {
            var added = false
            for key in ["content", "parts"] {
                guard var blocks = message[key] as? [[String: Any]],
                      let last = blocks.lastIndex(where: { $0["text"] is String }),
                      let text = blocks[last]["text"] as? String else { continue }
                blocks[last]["text"] = text + "\n\n" + note
                message[key] = blocks
                added = true
                break
            }
            guard added else { return history }
        }
        history[index] = message
        return history
    }

    // MARK: - For the wearer (localized)

    /// The heading over the held actions under a reply.
    static var screenHeading: String {
        String(localized: "Held, not run",
               comment: "Chat, under an assistant reply: actions the reply's turn asked for that did not run and are waiting for the user's OK (for example a Shortcut held while they were away).")
    }

    /// The line under the held actions: how to get one run.
    static var screenHint: String {
        String(localized: "Ask again to run it. You'll be asked to approve it first.",
               comment: "Chat, under the 'Held, not run' list on an assistant reply: how the user gets a held action run.")
    }

    /// One VoiceOver sentence for the whole group.
    static func spokenLabel(_ held: [String]) -> String {
        let list = cleaned(held).joined(separator: "; ")
        return String(localized: "Held, not run: \(list). Ask again to run it.",
                      comment: "VoiceOver, chat: the actions held under an assistant reply, then how to get one run.")
    }

    // MARK: -

    static func cleaned(_ held: [String]) -> [String] {
        var seen = Set<String>()
        return held.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
