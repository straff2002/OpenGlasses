import Foundation

/// A call's arguments as canonical JSON, so equal calls compare equal whatever order Swift's
/// dictionary gives their keys. Kept apart from the rest of `AttemptToolLedger`
/// (`HopAfterTools.swift`) so the local tool loop's repeat detection compiles on its own: the
/// device qualification app (`Scripts/local-model-qualification`, Plan MQ P3) builds these lines
/// as they ship. Moved unchanged.
extension AttemptToolLedger {

    /// Arguments as canonical JSON (sorted keys), the shape a model reads back most easily.
    static func canonicalArguments(_ args: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(args),
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same for arguments that arrived as a JSON string (the on-device runner's); a string
    /// that is not an object is kept as it came.
    static func canonicalArguments(json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json.isEmpty ? "{}" : json
        }
        return canonicalArguments(object)
    }
}
