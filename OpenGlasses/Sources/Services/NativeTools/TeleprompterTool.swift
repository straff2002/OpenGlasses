import Foundation

/// Drives the hands-free HUD teleprompter (`TeleprompterService`): start a script (provided
/// inline or by saved name), control playback (next/back/pause/resume/restart/stop), nudge
/// the pace (faster/slower), and manage saved scripts (list/save).
@MainActor
struct TeleprompterTool: NativeTool {
    let service: TeleprompterService
    /// Optional source for starting from a saved knowledge-base document (Document-RAG adapter).
    var documentStore: DocumentStore?
    /// Resolves the active project's namespace (Plan AN). Defaults to "global" when unset or no
    /// project is active. Document lookup is scoped through this so one chat can never read another
    /// project's document by name.
    var activeNamespace: (() -> String)?

    /// Namespaces a document lookup may read: the active project plus shared "global".
    private func scopedNamespaces() -> [String] {
        let ns = activeNamespace?() ?? "global"
        return ns == "global" ? ["global"] : ["global", ns]
    }

    let name = "teleprompter"
    let description = """
        Hands-free teleprompter on the in-lens HUD. Shows a script a window at a time and \
        (in audio-paced mode) auto-advances by listening to you read. Sources: inline text, a \
        saved script, a captured page (action=scan), or one of the user's saved documents \
        (document=<name>).
        """
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": [
                "type": "string",
                "enum": ["start", "stop", "pause", "resume", "next", "back", "restart",
                         "faster", "slower", "list", "save", "scan"],
                "description": "What to do. 'scan' captures a page through the camera and OCRs it; repeat to add pages, then 'start' (or 'save')."
            ],
            "text": [
                "type": "string",
                "description": "Script text for action=start (prompt it now) or action=save (store it)."
            ],
            "script": [
                "type": "string",
                "description": "Name of a previously-saved script to start (action=start)."
            ],
            "document": [
                "type": "string",
                "description": "Name of a saved knowledge-base document to prompt from (action=start)."
            ],
            "title": [
                "type": "string",
                "description": "Optional title when saving or starting inline text."
            ],
            "mode": [
                "type": "string",
                "enum": ["audio_paced", "voice", "auto_scroll"],
                "description": "Pacing mode for action=start. Defaults to the saved preference."
            ]
        ],
        "required": ["action"]
    ]

    func execute(args: [String: Any]) async throws -> String {
        let action = (args["action"] as? String)?.lowercased() ?? ""
        let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scriptName = (args["script"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentName = (args["document"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = parseMode(args["mode"] as? String)

        switch action {
        case "start":
            if let text, !text.isEmpty {
                let parsed = TeleprompterScript.parse(title: title ?? SavedScript.deriveTitle(from: text), text: text)
                service.start(parsed, mode: mode)
                return "Teleprompter started: \(parsed.title) (\(parsed.wordCount) words, \(service.mode.displayName))."
            }
            if let scriptName, let saved = service.store.script(named: scriptName) {
                service.start(savedID: saved.id, mode: mode)
                return "Teleprompter started: \(saved.title) (\(service.mode.displayName))."
            }
            if scriptName != nil {
                return "I couldn't find a saved script named \"\(scriptName!)\". Say \"list\" to see saved scripts."
            }
            if let documentName, !documentName.isEmpty {
                guard let store = documentStore else { return "Documents aren't available right now." }
                guard let doc = store.document(named: documentName, namespaces: scopedNamespaces()),
                      let raw = store.fullText(documentId: doc.id) else {
                    return "I couldn't find a saved document named \"\(documentName)\"."
                }
                let parsed = TeleprompterScript.parse(title: doc.name,
                                                      text: DocumentReconstructor.scriptLines(raw))
                guard parsed.wordCount > 0 else { return "\"\(doc.name)\" had no readable text to prompt." }
                service.start(parsed, mode: mode)
                return "Teleprompter started from document: \(doc.name) (\(parsed.wordCount) words, \(service.mode.displayName))."
            }
            if service.hasScannedPages {
                let pages = service.scanPages
                service.startScannedScript(title: title, mode: mode)
                return "Teleprompter started from \(pages) scanned page\(pages == 1 ? "" : "s") (\(service.mode.displayName))."
            }
            return "Provide the script text, a saved script name, a document name, or scan a page first."

        case "stop":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.stop()
            return "Teleprompter stopped."

        case "pause":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.pause()
            return "Paused."

        case "resume":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.resume()
            return "Resumed."

        case "next":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.advance()
            return "Next line."

        case "back":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.back()
            return "Back one line."

        case "restart":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.restart()
            return "Back to the top."

        case "faster":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.nudgeSpeed(faster: true)
            return "Faster."

        case "slower":
            guard service.isActive else { return "The teleprompter isn't running." }
            service.nudgeSpeed(faster: false)
            return "Slower."

        case "list":
            let scripts = service.store.scripts
            guard !scripts.isEmpty else { return "No saved scripts yet. Save one with action=save." }
            let names = scripts.prefix(20).map { "• \($0.title)" }.joined(separator: "\n")
            return "Saved scripts:\n\(names)"

        case "scan":
            return await service.scanPage()

        case "save":
            if let text, !text.isEmpty {
                let saved = service.store.add(title: title ?? "", text: text)
                return "Saved teleprompter script \"\(saved.title)\"."
            }
            if let saved = service.saveScannedScript(title: title) {
                return "Saved scanned teleprompter script \"\(saved.title)\"."
            }
            return "Provide the script text to save, or scan a page first."

        default:
            return "Unknown action. Use start, stop, pause, resume, next, back, restart, faster, slower, list, save, or scan."
        }
    }

    private func parseMode(_ raw: String?) -> PacingMode? {
        switch raw?.lowercased() {
        case "audio_paced", "audiopaced", "audio": return .audioPaced
        case "voice", "manual": return .voice
        case "auto_scroll", "autoscroll", "scroll": return .autoScroll
        default: return nil
        }
    }
}
