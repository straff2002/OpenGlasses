import Foundation

/// A native tool's JSON-schema parameters, read into the compact shape both on-device paths take
/// (Plan JD P0; shared with the downloaded models under Plan MQ P0).
///
/// Every `NativeTool` describes its arguments as a JSON-schema dictionary — the shape every cloud
/// provider's declarations are built from. Apple's Foundation Models framework takes its own
/// `GenerationSchema` instead, and it is built from typed values, not a dictionary. This is the
/// pure reading between the two: a small tree the bridge turns into Apple's types one-to-one, with
/// no Foundation Models import, so every tool's conversion can be asserted headlessly.
///
/// The downloaded (MLX and GGUF) models read the same tree, rendered back to a short JSON schema by
/// `localParameters(_:)`: the same condensed descriptions, the same choices, the same order. That
/// rendering adds the two rules a small model's chat template needs — every node carries a `type`,
/// and nesting stops at `localMaxDepth` — and `OnDeviceArgumentCoercion` reads a call's arguments
/// back to the declared types before anything is dispatched. The Apple path's own conversion is not
/// changed by either; it reads this type through the `AppleToolSchema` alias.
///
/// The on-device model has a 4,096-token context window shared by instructions, tool definitions
/// and the conversation, so every description is **condensed** on the way through: a tool's
/// description keeps its first sentences up to `Limits.toolDescription` characters, a property's
/// up to `Limits.propertyDescription`. The cut lands on a sentence boundary when one is in reach,
/// so what survives is still a sentence the model can act on, not a fragment.
enum OnDeviceToolSchema {

    /// One node of the converted schema.
    indirect enum Node: Equatable {
        /// A string, constrained to `choices` when the schema declared an `enum`.
        case string(choices: [String]?)
        case integer
        case number
        case boolean
        case array(Node)
        /// `name` is the unique type name Apple's schema needs for every object (nested objects are
        /// named by their path, `tool_property`, so two tools can share a property name).
        case object(name: String, description: String?, properties: [Property])
    }

    struct Property: Equatable {
        let name: String
        let description: String?
        let node: Node
        /// `true` unless the enclosing object listed the property under `required`.
        let isOptional: Bool
    }

    /// How much of each description survives. Characters, not tokens: the estimate below is what
    /// the budget reasons in, but a cut has to land in text.
    struct Limits: Equatable {
        var toolDescription: Int
        var propertyDescription: Int
        /// An `enum` longer than this is rendered as free text with the choices named in the
        /// description instead — the constrained form costs a token per choice.
        var maxChoices: Int
        /// The cut for an optional property's description; nil: the same as `propertyDescription`.
        /// 0 drops it (the property keeps its name, its `type` and its choices).
        var optionalPropertyDescription: Int? = nil

        static let standard = Limits(toolDescription: 360, propertyDescription: 150, maxChoices: 24)

        /// The downloaded models' fallback when the standard definitions don't fit the prompt
        /// (Plan MQ P3, `LocalToolFit`): a two-sentence tool description, a required property's
        /// description cut hard, an optional property's dropped. Every node keeps its `type` and its
        /// choices; nesting is unchanged. Never used on the Apple path.
        static let compact = Limits(toolDescription: 160, propertyDescription: 100, maxChoices: 24,
                                    optionalPropertyDescription: 0)
    }

    /// The converted root for one tool. The root is always an object named after the tool, even
    /// when the tool declared no parameters at all, because that is the only shape a tool's
    /// `parameters` schema may have.
    static func root(toolName: String, parameters: [String: Any],
                     limits: Limits = .standard) -> Node {
        let node = Self.node(from: parameters, path: toolName, limits: limits)
        if case .object = node { return node }
        return .object(name: toolName, description: nil, properties: [])
    }

    /// The condensed description a tool definition carries.
    static func toolDescription(_ description: String, limits: Limits = .standard) -> String {
        condense(description, limit: limits.toolDescription)
    }

    /// One node, read from a schema fragment. An unknown or missing `type` reads as a string: the
    /// model can always produce text, and the tool parses what it is given as it always has.
    static func node(from schema: [String: Any], path: String, limits: Limits) -> Node {
        let type = (schema["type"] as? String)?.lowercased() ?? "string"
        switch type {
        case "object":
            let required = Set((schema["required"] as? [String]) ?? [])
            let raw = (schema["properties"] as? [String: Any]) ?? [:]
            // Sorted so the rendered definition is stable between launches — a dictionary's order
            // is not, and a changing definition would read as a changing tool to the model.
            let properties: [Property] = raw.keys.sorted().compactMap { key in
                guard let fragment = raw[key] as? [String: Any] else { return nil }
                let limit = required.contains(key)
                    ? limits.propertyDescription
                    : (limits.optionalPropertyDescription ?? limits.propertyDescription)
                var description = limit > 0
                    ? (fragment["description"] as? String)
                        .map { condense($0, limit: limit) }
                        .flatMap { $0.isEmpty ? nil : $0 }
                    : nil
                if let suffix = choicesSuffix(for: fragment, limits: limits) {
                    description = [description, suffix].compactMap { $0 }.joined(separator: " ")
                }
                return Property(name: key,
                                description: description,
                                node: node(from: fragment, path: "\(path)_\(key)", limits: limits),
                                isOptional: !required.contains(key))
            }
            let description = (schema["description"] as? String)
                .map { condense($0, limit: limits.propertyDescription) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return .object(name: path, description: description, properties: properties)
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            let items = (schema["items"] as? [String: Any]) ?? ["type": "string"]
            return .array(node(from: items, path: "\(path)_item", limits: limits))
        default:
            if let choices = schema["enum"] as? [String], !choices.isEmpty,
               choices.count <= limits.maxChoices {
                return .string(choices: choices)
            }
            return .string(choices: nil)
        }
    }

    /// A property whose `enum` was too long to constrain still tells the model its choices, in the
    /// description. Pure, so the bridge and the tests agree on the text.
    static func choicesSuffix(for schema: [String: Any], limits: Limits = .standard) -> String? {
        guard let choices = schema["enum"] as? [String], choices.count > limits.maxChoices else {
            return nil
        }
        return "One of: " + choices.joined(separator: ", ")
    }

    // MARK: - Condensing

    /// `text` with its whitespace collapsed and cut to `limit` characters on a sentence boundary
    /// when one lies in the second half of the budget, else on a word boundary with an ellipsis.
    static func condense(_ text: String, limit: Int) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > limit, limit > 0 else { return collapsed }
        let window = String(collapsed.prefix(limit))
        // The last sentence end inside the window: ". ", "! " or "? " followed by a space, or a
        // terminal mark that happens to sit exactly at the cut.
        if let end = lastSentenceEnd(in: window), end >= limit / 2 {
            return String(window.prefix(end + 1))
        }
        if let space = window.lastIndex(of: " "), window.distance(from: window.startIndex, to: space) >= limit / 2 {
            return String(window[..<space]) + "…"
        }
        return window + "…"
    }

    private static func lastSentenceEnd(in text: String) -> Int? {
        let characters = Array(text)
        var index = characters.count - 1
        while index >= 0 {
            let character = characters[index]
            if character == "." || character == "!" || character == "?" {
                // A mark counts as a sentence end when it is followed by a space or ends the text.
                // "e.g." and "1.5" have a letter or digit after the mark and are skipped.
                if index == characters.count - 1 || characters[index + 1] == " " {
                    // Not a decimal point or an abbreviation of the form "x." inside a word.
                    if index > 0, characters[index - 1].isNumber, index + 1 < characters.count,
                       characters[index + 1].isNumber {
                        index -= 1
                        continue
                    }
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Size

    /// A rough token count for one converted tool: name, description, and every property's name,
    /// description, type and choices, at four characters a token plus a per-field overhead for the
    /// framework's rendering. Deliberately pessimistic — the budget it feeds is a ceiling.
    static func estimatedTokens(name: String, description: String, root: Node) -> Int {
        var characters = name.count + description.count
        var fields = 1
        func walk(_ node: Node) {
            switch node {
            case .string(let choices):
                characters += choices.map { $0.reduce(0) { $0 + $1.count + 2 } } ?? 0
            case .integer, .number, .boolean:
                break
            case .array(let item):
                walk(item)
            case .object(let objectName, let description, let properties):
                characters += objectName.count + (description?.count ?? 0)
                for property in properties {
                    fields += 1
                    characters += property.name.count + (property.description?.count ?? 0)
                    walk(property.node)
                }
            }
        }
        walk(root)
        return characters / 4 + fields * 6
    }
}

// MARK: - The downloaded models' rendering (Plan MQ P0)

extension OnDeviceToolSchema {

    // MARK: Size, calibrated on a phone (Plan MQ P3)

    /// Bytes of a rendered spec's compact JSON per token of Gemma 4 E2B's real template render, with
    /// a margin. Calibrated from the first phone run (2026-11-22, iPhone Air, mlx-swift-lm
    /// `4c21c84`): the Field Assist job prompt with the native tool guide (6,234 characters, about
    /// 1,560 tokens at four characters a token), a 52–75 character turn and four definitions
    /// (`reading`, `field_session`, `table_lookup`, `domain_calc`: 10,034 bytes of spec JSON)
    /// measured 4,317–4,326 tokens. That leaves about 2,750 tokens for the definitions: 3.65 bytes
    /// a token. 3.4, with `localPerToolTokens` for each declaration's wrapper, puts the whole prompt
    /// at 4,556–4,561, 5–6% above the phone, so a selection made with it rarely leaves the runtime
    /// fit (`LocalToolFit`) anything to drop. `estimatedTokens` above, the Apple path's figure and
    /// what the native selection used before, put the same prompt at 3,726–3,731 (its four tools
    /// at 2,155, about 22% under the render): it counts no JSON keys, types or punctuation. The
    /// split assumes the prompt reads at four characters a token; the record's per-generation
    /// prompt counts settle it. `FieldAssistContextAuditTests` rechecks it against the phone.
    static let localCharactersPerToken = 3.4

    /// Tokens for each declaration's template wrapper (its open and close markers and separators).
    static let localPerToolTokens = 8

    /// Gemma 4 E2B's real tokens for one rendered spec (`localToolSpec`), estimated from its JSON.
    /// What the downloaded models' tool selection budgets with; the Apple path keeps
    /// `estimatedTokens`.
    static func localEstimatedTokens(spec: [String: Any]) -> Int {
        let bytes = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]))?.count ?? 0
        return Int((Double(bytes) / localCharactersPerToken).rounded(.up)) + localPerToolTokens
    }

    /// How deep a rendered schema may nest. The root object is level 1; an object or array inside it
    /// is level 2. Anything deeper is rendered as a string that holds JSON, which
    /// `OnDeviceArgumentCoercion` parses back. Gemma 4's chat template walks a schema with a
    /// recursive macro, and a deep tree can overflow the template engine's stack.
    static let localMaxDepth = 2

    /// The JSON-schema dictionary a downloaded model's chat template renders for one tool's
    /// parameters: the converted tree, written back with a `type` on every node (Gemma 4's template
    /// fails on a node without one) and nesting cut at `localMaxDepth`. Keys keep the tree's sorted
    /// order through `required`, so the rendering is stable between launches.
    static func localParameters(_ root: Node) -> [String: Any] {
        localSchema(root, depth: 1)
    }

    /// One tool in the `{"type": "function", "function": {…}}` shape mlx-swift-lm's `ToolSpec` and
    /// llama.cpp's chat templates take: the condensed description and `localParameters`.
    static func localToolSpec(name: String, description: String, parameters: [String: Any],
                              limits: Limits = .standard) -> [String: Any] {
        let root = Self.root(toolName: name, parameters: parameters, limits: limits)
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": toolDescription(description, limits: limits),
                "parameters": localParameters(root),
            ] as [String: Any],
        ]
    }

    private static func localSchema(_ node: Node, depth: Int, description: String? = nil) -> [String: Any] {
        // A container past the limit becomes text holding JSON; a scalar at any depth is itself.
        if depth > localMaxDepth, node.isContainer {
            return ["type": "string", "description": flattenedNote(description)]
        }
        var schema: [String: Any]
        switch node {
        case .string(let choices):
            schema = ["type": "string"]
            if let choices { schema["enum"] = choices }
        case .integer:
            schema = ["type": "integer"]
        case .number:
            schema = ["type": "number"]
        case .boolean:
            schema = ["type": "boolean"]
        case .array(let item):
            schema = ["type": "array", "items": localSchema(item, depth: depth + 1)]
        case .object(_, let objectDescription, let properties):
            var rendered: [String: Any] = [:]
            for property in properties {
                rendered[property.name] = localSchema(property.node, depth: depth + 1,
                                                      description: property.description)
            }
            schema = ["type": "object", "properties": rendered]
            let required = properties.filter { !$0.isOptional }.map(\.name)
            if !required.isEmpty { schema["required"] = required }
            if description == nil, let objectDescription { schema["description"] = objectDescription }
        }
        if let description { schema["description"] = description }
        return schema
    }

    private static func flattenedNote(_ description: String?) -> String {
        [description, "Give this as a JSON value written as text."].compactMap { $0 }.joined(separator: " ")
    }
}

extension OnDeviceToolSchema.Node {
    /// An object, or an array of anything: a node that adds a level of nesting.
    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        case .string, .integer, .number, .boolean: return false
        }
    }

    /// The declared type's name, for a refusal message. Never a value.
    var typeName: String {
        switch self {
        case .string(let choices): return choices == nil ? "string" : "one of the listed choices"
        case .integer: return "integer"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Argument coercion

/// A downloaded model's call arguments, read back to the types the tool declared before the call is
/// dispatched (Plan MQ P0). Pure.
///
/// Small models get a type wrong in a few predictable ways: a number as text (`"42"` for an integer,
/// seen from Gemma 4 E2B at 4-bit), a number for a string (`108` for a job number), `"true"` for a
/// boolean, a nested object written out as JSON text. Each of those has exactly one reading, and
/// this takes it. Anything that doesn't — `"about forty"` for a number, `"45 psi"` with its unit,
/// `1` for a boolean, a choice that isn't listed — is **refused** rather than guessed: an invented
/// value is worse than an error the model can read and correct.
///
/// Explicit `null`s are dropped, as `AppleToolArguments` drops them, so an optional the model
/// spelled out as null reads as absent. Arguments the schema doesn't declare pass through untouched;
/// the router's authorization, not this, decides what they mean.
///
/// One misnamed argument has one reading too (Plan MQ P3): a required choice that is missing, when
/// exactly one other key holds one of its choices and could not keep it — undeclared, or declared
/// with choices that don't include it. Gemma 4 E2B on the phone sent `application: "voltage_drop"`
/// for `operation` in 7 of 8 two-step calls; the value is moved to the required key. Nothing else
/// is renamed: not onto a key that is present, not for a target without choices, not when two keys
/// could be meant.
enum OnDeviceArgumentCoercion {

    enum Problem: Equatable {
        /// The value at `path` can't be read as `expected`. Neither the value nor the arguments
        /// are carried, so a problem is safe to log as a count and to show the model.
        case wrongType(path: String, expected: String)
        /// A property the schema marks as required is missing.
        case missingRequired(path: String)

        /// One sentence the model reads as the tool's result, naming the field and the type only.
        var message: String {
            switch self {
            case .wrongType(let path, let expected): return "Argument '\(path)' must be \(articled(expected))."
            case .missingRequired(let path): return "Argument '\(path)' is required."
            }
        }

        private func articled(_ type: String) -> String {
            switch type {
            case "integer", "object", "array": return "an \(type)"
            case "one of the listed choices": return type
            default: return "a \(type)"
            }
        }
    }

    struct Result {
        /// The arguments with every declared value at its declared type.
        let arguments: [String: Any]
        let problems: [Problem]
        /// How many values were changed to reach their declared type. Counted for the report.
        let coercedCount: Int

        /// True when the call may be dispatched: nothing was refused.
        var isDispatchable: Bool { problems.isEmpty }
        /// The problems as one tool-result line, or nil when there are none.
        var refusalMessage: String? {
            problems.isEmpty ? nil : "Error: " + problems.map(\.message).joined(separator: " ")
        }
    }

    static func coerce(_ arguments: [String: Any], to root: OnDeviceToolSchema.Node) -> Result {
        var state = State()
        let value = coerceObject(arguments, node: root, path: "", state: &state)
        return Result(arguments: value ?? arguments, problems: state.problems, coercedCount: state.coerced)
    }

    private struct State {
        var problems: [Problem] = []
        var coerced = 0
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private static func coerceObject(_ object: [String: Any], node: OnDeviceToolSchema.Node,
                                     path: String, state: inout State) -> [String: Any]? {
        guard case .object(_, _, let properties) = node else { return object }
        var result = object.filter { !($0.value is NSNull) }
        repairMisnamedChoices(&result, properties: properties, state: &state)
        for property in properties {
            let propertyPath = join(path, property.name)
            guard let raw = result[property.name] else {
                if !property.isOptional { state.problems.append(.missingRequired(path: propertyPath)) }
                continue
            }
            if let value = coerceValue(raw, node: property.node, path: propertyPath, state: &state) {
                result[property.name] = value
            }
        }
        return result
    }

    /// Moves a missing required choice back from the one key that holds it under another name.
    /// Counted as a coercion; the key's name and value are never recorded.
    private static func repairMisnamedChoices(_ object: inout [String: Any],
                                              properties: [OnDeviceToolSchema.Property], state: inout State) {
        let declared = Dictionary(properties.map { ($0.name, $0.node) }, uniquingKeysWith: { first, _ in first })
        for property in properties where !property.isOptional && object[property.name] == nil {
            guard case .string(let choices?) = property.node else { continue }
            let folded = Set(choices.map { $0.lowercased() })
            let holders = object.compactMap { key, value -> String? in
                guard let text = value as? String,
                      folded.contains(text.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
                // A declared key keeps a value it can take; only one it would refuse can be misnamed.
                if let own = declared[key], accepts(own, text) { return nil }
                return key
            }
            guard holders.count == 1, let key = holders.first, let value = object.removeValue(forKey: key) else { continue }
            object[property.name] = value
            state.coerced += 1
        }
    }

    /// Whether `node` reads `text` as a value of its own, as `coerceValue` would.
    private static func accepts(_ node: OnDeviceToolSchema.Node, _ text: String) -> Bool {
        let folded = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch node {
        case .string(let choices): return choices.map { $0.contains { $0.lowercased() == folded } } ?? true
        case .integer, .number: return plainNumber(text) != nil
        case .boolean: return folded == "true" || folded == "false"
        case .array(let item): return accepts(item, text)
        case .object: return false
        }
    }

    /// The value at its declared type, or nil (with a problem recorded) when it has no single reading.
    private static func coerceValue(_ value: Any, node: OnDeviceToolSchema.Node, path: String,
                                    state: inout State) -> Any? {
        switch node {
        case .string(let choices):
            guard let text = stringValue(value) else {
                state.problems.append(.wrongType(path: path, expected: node.typeName))
                return nil
            }
            if !(value is String) { state.coerced += 1 }
            guard let choices else { return text }
            if choices.contains(text) { return text }
            // A choice in the wrong case has one reading; a choice that isn't listed has none.
            let folded = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = choices.first(where: { $0.lowercased() == folded }) {
                state.coerced += 1
                return match
            }
            state.problems.append(.wrongType(path: path, expected: node.typeName))
            return nil
        case .integer:
            if let number = value as? NSNumber, !isBoolean(number) {
                let double = number.doubleValue
                guard double.rounded() == double, abs(double) < 9.0e15 else { break }
                if CFNumberIsFloatType(number) { state.coerced += 1 }
                return Int(double)
            }
            if let text = value as? String, let double = plainNumber(text), double.rounded() == double,
               abs(double) < 9.0e15 {
                state.coerced += 1
                return Int(double)
            }
        case .number:
            if let number = value as? NSNumber, !isBoolean(number) { return number }
            if let text = value as? String, let double = plainNumber(text) {
                state.coerced += 1
                return double
            }
        case .boolean:
            if let number = value as? NSNumber, isBoolean(number) { return number.boolValue }
            if let text = value as? String {
                switch text.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true": state.coerced += 1; return true
                case "false": state.coerced += 1; return false
                default: break
                }
            }
        case .array(let item):
            var elements: [Any]
            if let array = value as? [Any] {
                elements = array
            } else if let text = value as? String, let parsed = parsedJSON(text) as? [Any] {
                elements = parsed
                state.coerced += 1
            } else if !(value is [String: Any]) {
                // One value where a list was declared has one reading: the list of that value.
                elements = [value]
                state.coerced += 1
            } else {
                break
            }
            var coerced: [Any] = []
            for (index, element) in elements.enumerated() where !(element is NSNull) {
                guard let value = coerceValue(element, node: item, path: "\(path)[\(index)]", state: &state) else {
                    return nil
                }
                coerced.append(value)
            }
            return coerced
        case .object:
            if let object = value as? [String: Any] {
                return coerceObject(object, node: node, path: path, state: &state)
            }
            if let text = value as? String, let object = parsedJSON(text) as? [String: Any] {
                state.coerced += 1
                return coerceObject(object, node: node, path: path, state: &state)
            }
        }
        state.problems.append(.wrongType(path: path, expected: node.typeName))
        return nil
    }

    /// A value read as text: text itself, or a number written the way a person would write it.
    /// A boolean, a list or an object has no single reading as text.
    private static func stringValue(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber, !isBoolean(number) {
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < 9.0e15 { return String(Int(double)) }
            return number.stringValue
        }
        return nil
    }

    /// A number written as plain text — digits, an optional sign and one decimal point, nothing
    /// else. "42", " 4.5 ", "-3", ".5" read; "45 psi", "1,200", "4.5.1", "forty" and "" don't.
    static func plainNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.range(of: #"^[+-]?(\d+(\.\d*)?|\.\d+)$"#,
                                              options: .regularExpression) != nil else { return nil }
        return Double(trimmed)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func parsedJSON(_ text: String) -> Any? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
