import Foundation

/// Append-only audit log for a single Field Assist session.
///
/// Each session lives in `Documents/FieldSessions/{session_id}/`:
///   - `session.json` — session metadata (started_at, vault, asset, outcome, etc.)
///   - `log.jsonl` — newline-delimited JSON events (one per line, append-only)
///   - `photos/` — captured photos attached via `PhotoLogTool`
///
/// The append-only design preserves a defensible audit trail for compliance use cases
/// (EPA 608 refrigerant recovery, warranty submissions, work-order records).
final class SessionLogger {
    let session: FieldSession
    let root: URL

    private let logURL: URL
    private let sessionMetaURL: URL
    private let photosDir: URL
    private let queue = DispatchQueue(label: "openglasses.sessionlogger", qos: .utility)

    init(session: FieldSession, root: URL? = nil) {
        self.session = session
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.root = root ?? documents.appendingPathComponent("FieldSessions/\(session.id)", isDirectory: true)
        self.logURL = self.root.appendingPathComponent("log.jsonl")
        self.sessionMetaURL = self.root.appendingPathComponent("session.json")
        self.photosDir = self.root.appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        writeSessionMeta()
    }

    // MARK: - Event Types

    /// One event in the audit log. Keep `payload` JSON-encodable.
    struct Event: Codable {
        let timestamp: Date
        let kind: Kind
        let text: String?
        let payload: [String: AnyCodable]?

        enum Kind: String, Codable {
            case sessionStarted = "session_started"
            case sessionPaused = "session_paused"
            case sessionResumed = "session_resumed"
            case sessionEnded = "session_ended"
            case userMessage = "user_message"
            case assistantMessage = "assistant_message"
            case toolCall = "tool_call"
            case photoAttached = "photo_attached"
            case procedureStarted = "procedure_started"
            case procedureStep = "procedure_step"
            case procedureCompleted = "procedure_completed"
            case escalationRequested = "escalation_requested"
            case escalationResolved = "escalation_resolved"
            case citation = "citation"
            case error = "error"
        }
    }

    // MARK: - Append API

    /// Append a generic event.
    func append(_ event: Event) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(event) else { return }
            let line = (String(data: data, encoding: .utf8) ?? "") + "\n"
            guard let bytes = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: bytes)
            } else {
                _ = try? bytes.write(to: logURL, options: .atomic)
            }
        }
    }

    /// Convenience: append a session-lifecycle event.
    func appendLifecycle(_ kind: Event.Kind, note: String? = nil) {
        append(Event(timestamp: Date(), kind: kind, text: note, payload: nil))
    }

    /// Convenience: append a user message.
    func appendUserMessage(_ text: String) {
        append(Event(timestamp: Date(), kind: .userMessage, text: text, payload: nil))
    }

    /// Convenience: append an assistant message, optionally with cited sources.
    func appendAssistantMessage(_ text: String, citations: [String]? = nil) {
        let payload: [String: AnyCodable]? = citations.map { ["citations": AnyCodable($0)] }
        append(Event(timestamp: Date(), kind: .assistantMessage, text: text, payload: payload))
    }

    /// Read back all events from the append-only log, in write order.
    /// Malformed lines are skipped — the log remains usable after a partial/truncated write.
    /// Used for crash recovery (e.g. reconstructing an in-progress procedure).
    func readEvents() -> [Event] {
        queue.sync {
            guard let raw = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var events: [Event] = []
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(Event.self, from: data) else { continue }
                events.append(event)
            }
            return events
        }
    }

    // MARK: - Session metadata

    /// Write the current session metadata snapshot. Call after lifecycle changes.
    @discardableResult
    func updateSession(_ updater: (inout FieldSession) -> Void) -> FieldSession {
        var copy = session
        updater(&copy)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(copy) {
            try? data.write(to: sessionMetaURL, options: .atomic)
        }
        return copy
    }

    private func writeSessionMeta() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(session) {
            try? data.write(to: sessionMetaURL, options: .atomic)
        }
    }

    // MARK: - Photo Attachment

    /// Save photo bytes into the session's photos dir and append a log event.
    /// Returns the on-disk URL of the saved photo.
    @discardableResult
    func attachPhoto(_ data: Data, caption: String? = nil, fileExtension: String = "jpg") -> URL {
        let filename = "\(ISO8601DateFormatter().string(from: Date()))_\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let url = photosDir.appendingPathComponent(filename)
        try? data.write(to: url, options: .atomic)
        var payload: [String: AnyCodable] = ["path": AnyCodable(url.lastPathComponent)]
        if let caption { payload["caption"] = AnyCodable(caption) }
        append(Event(timestamp: Date(), kind: .photoAttached, text: caption, payload: payload))
        return url
    }
}

// MARK: - AnyCodable

/// A minimal type-erased Codable container for heterogeneous payloads.
/// Used by SessionLogger to encode mixed-type event payloads without per-event types.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull, Optional<Any>.none:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
