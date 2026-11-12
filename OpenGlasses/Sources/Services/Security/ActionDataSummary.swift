import Foundation

/// What kind of data a call carries, and where it goes, for the approval copy of a tool this app
/// has not reviewed (Plan LP §5). Pure and table-driven.
///
/// "Run trip_planner: lat=51.5, lon=-0.12" asks a person to read keys and values and work out what
/// they mean. "Send location coordinates to 'trip-planner'" says it. Only what the table can tell
/// is named; every argument it cannot place is still shown, in the old key=value form, so the
/// card never covers less than it used to.
enum ActionDataSummary {

    enum Kind: String, CaseIterable, Equatable {
        case coordinates, address, photo, file, health, contact, message, text

        /// How the kind reads in "Send … to 'x'".
        var phrase: String {
            switch self {
            case .coordinates: return "location coordinates"
            case .address: return "an address"
            case .photo: return "a photo"
            case .file: return "a file"
            case .health: return "health data"
            case .contact: return "contact details"
            case .message: return "a message"
            case .text: return "some text"
            }
        }

        /// Whether the value itself is worth quoting, as the message tools' copy quotes a body.
        var quotesValue: Bool { self == .message || self == .text }
    }

    /// Argument keys by the kind of data they carry. Lower-cased; matched whole.
    static let keys: [(Kind, Set<String>)] = [
        (.coordinates, ["lat", "lon", "lng", "latitude", "longitude", "coordinates", "coords",
                        "current_location", "gps"]),
        (.address, ["address", "street_address", "postcode", "zip", "location", "place"]),
        (.photo, ["photo", "image", "image_data", "image_base64", "picture", "frame", "snapshot",
                  "image_url", "photo_url"]),
        (.file, ["file", "file_path", "filepath", "path", "attachment", "document", "filename",
                 "file_url"]),
        (.health, ["health", "health_data", "heart_rate", "steps", "blood_pressure", "glucose",
                   "weight", "medication", "medications", "diagnosis", "symptoms", "workout",
                   "sleep"]),
        (.contact, ["contact", "contacts", "phone", "phone_number", "email", "email_address",
                    "vcard"]),
        (.message, ["body", "message"]),
        (.text, ["text", "content", "query", "q", "prompt", "note"]),
    ]

    /// The kind an argument carries, from its key — or, for a value that is plainly an image or a
    /// file reference, from the value.
    static func kind(key: String, value: Any) -> Kind? {
        let lowered = key.lowercased()
        if let match = keys.first(where: { $0.1.contains(lowered) }) { return match.0 }
        if let string = value as? String {
            if string.hasPrefix("data:image/") { return .photo }
            if string.hasPrefix("file://") { return .file }
        }
        return nil
    }

    /// The approval line for an external call, or nil when no argument is one the table knows —
    /// the caller then keeps today's form.
    ///
    /// - Parameter destination: who receives it — the server's label for an MCP tool.
    static func summary(args: [String: Any], destination: String?) -> String? {
        var kinds: [Kind] = []
        var quoted: [String] = []
        var rest: [(String, Any)] = []
        for (key, value) in args.sorted(by: { $0.key < $1.key }) {
            guard let kind = kind(key: key, value: value) else {
                rest.append((key, value))
                continue
            }
            if !kinds.contains(kind) { kinds.append(kind) }
            if kind.quotesValue, let text = value as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                quoted.append("“\(preview(text, max: 80))”")
            }
        }
        guard !kinds.isEmpty else { return nil }
        // Table order, not argument order, so the same call always reads the same way.
        let ordered = Kind.allCases.filter(kinds.contains).map(\.phrase)
        var line = "Send \(join(ordered))"
        if let destination, !destination.isEmpty { line += " to '\(destination)'" }
        if !quoted.isEmpty { line += ": \(quoted.joined(separator: ", "))" }
        if !rest.isEmpty {
            let shown = rest.prefix(3).map { "\($0.0)=\(preview(String(describing: $0.1), max: 40))" }
            let more = rest.count > 3 ? ", …" : ""
            line += ", with \(shown.joined(separator: ", "))\(more)"
        }
        return line
    }

    /// The destination an MCP tool's qualified name carries: `<server label>__<tool>`.
    static func serverLabel(fromQualifiedName name: String) -> String? {
        guard let range = name.range(of: "__"), range.lowerBound > name.startIndex else { return nil }
        return String(name[..<range.lowerBound])
    }

    private static func preview(_ text: String, max: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }

    private static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
