import Foundation

/// Extra fields for a Home Assistant service call, beyond `entity_id` (Plan GS P1, shared with the
/// TV-control plan's service-data need).
///
/// Deliberately an allowlist. A service call can do a great deal with arbitrary data — scripts,
/// notifications, shell commands on some installs — and the model supplies these values, so only
/// the handful of keys media control needs are accepted, each with a checked type and range.
struct HomeAssistantServiceData: Equatable, Sendable {

    enum Value: Equatable, Sendable {
        case string(String)
        case number(Double)
    }

    enum ValidationError: Error, Equatable {
        case keyNotAllowed(String)
        case wrongType(String)
        case outOfRange(String)
    }

    /// The keys a service call may carry, and what each must hold.
    static let allowedKeys: [String: Kind] = [
        "media_content_id": .text,
        "media_content_type": .text,
        "volume_level": .unitInterval,
        "source": .text,
    ]

    enum Kind: Equatable, Sendable {
        /// A non-empty string of at most `maxTextLength` characters.
        case text
        /// A number from 0 to 1.
        case unitInterval
    }

    static let maxTextLength = 512

    private(set) var values: [String: Value] = [:]

    static let empty = HomeAssistantServiceData()

    init() {}

    /// Build from typed values, validating each.
    init(_ values: [String: Value]) throws {
        for (key, value) in values {
            try Self.check(key: key, value: value)
        }
        self.values = values
    }

    /// Validate loosely-typed values as they arrive from a tool call's JSON arguments.
    static func validated(_ raw: [String: Any]) -> Result<HomeAssistantServiceData, ValidationError> {
        var typed: [String: Value] = [:]
        for (key, rawValue) in raw {
            guard let kind = allowedKeys[key] else { return .failure(.keyNotAllowed(key)) }
            switch kind {
            case .text:
                guard let text = rawValue as? String else { return .failure(.wrongType(key)) }
                typed[key] = .string(text)
            case .unitInterval:
                if let number = rawValue as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    typed[key] = .number(number.doubleValue)
                } else if let text = rawValue as? String, let number = Double(text) {
                    typed[key] = .number(number)
                } else {
                    return .failure(.wrongType(key))
                }
            }
        }
        do {
            return .success(try HomeAssistantServiceData(typed))
        } catch let error as ValidationError {
            return .failure(error)
        } catch {
            return .failure(.wrongType("data"))
        }
    }

    private static func check(key: String, value: Value) throws {
        guard let kind = allowedKeys[key] else { throw ValidationError.keyNotAllowed(key) }
        switch (kind, value) {
        case (.text, .string(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, text.count <= maxTextLength else { throw ValidationError.outOfRange(key) }
        case (.unitInterval, .number(let number)):
            guard number.isFinite, (0...1).contains(number) else { throw ValidationError.outOfRange(key) }
        default:
            throw ValidationError.wrongType(key)
        }
    }

    /// The JSON body for `POST /api/services/<domain>/<service>`.
    func body(entityId: String) -> [String: Any] {
        var body: [String: Any] = ["entity_id": entityId]
        for (key, value) in values {
            switch value {
            case .string(let text): body[key] = text
            case .number(let number): body[key] = number
            }
        }
        return body
    }

    /// A sentence the model can act on when validation fails.
    static func refusal(for error: ValidationError) -> String {
        let allowed = allowedKeys.keys.sorted().joined(separator: ", ")
        switch error {
        case .keyNotAllowed(let key):
            return "Home Assistant service data can't include '\(key)'. Allowed keys: \(allowed)."
        case .wrongType(let key):
            return "The value for '\(key)' has the wrong type."
        case .outOfRange(let key):
            return key == "volume_level"
                ? "volume_level must be a number from 0 to 1."
                : "The value for '\(key)' must be non-empty text of at most \(maxTextLength) characters."
        }
    }
}
