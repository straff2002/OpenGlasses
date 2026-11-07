import Foundation

/// A recipe add-on file, format `avenkin.addon/1`: one JSON document declaring either a few
/// skills (each a short list of steps) or one MCP server entry, plus the permissions it needs.
///
/// Decoding is **strict**: an unknown key anywhere the format defines the keys — top level,
/// `author`, `permissions`, `mcp`, a parameter, a skill, a step — rejects the file, so a typo can
/// never silently grant a permission or drop a limit. A wrong `format` tag, both `skills` and
/// `mcp`, or neither, is also a decode error. Limits and cross-references (lengths, hosts,
/// variables defined before use…) are the validator's job, not the decoder's: decoding answers
/// "is this the format?", `RecipeAddOnValidator` answers "is it allowed?".
///
/// Add-ons are a separate artifact from skill packs — not a `SkillPackBinding` kind — because the
/// trust models differ: an add-on composes nothing and is bounded by its permissions and sandbox.
struct RecipeAddOnManifest: Equatable, Sendable {

    static let formatTag = "avenkin.addon/1"

    let format: String
    let id: String
    let name: String
    let version: String
    let author: Author
    let description: String
    let icon: String?
    let coverage: [String]?
    let slow: Bool
    let minAppBuild: Int?
    let permissions: Permissions
    let content: Content

    enum Content: Equatable, Sendable {
        case skills([Skill])
        case mcp(MCPEntry)
    }

    var skills: [Skill] { if case .skills(let s) = content { return s }; return [] }
    var mcp: MCPEntry? { if case .mcp(let m) = content { return m }; return nil }

    struct Author: Equatable, Sendable {
        let name: String
        let web: String?
    }

    /// The four permissions the format has. None is granted by default; speaking needs none.
    struct Permissions: Equatable, Sendable {
        var network: [String]
        var location: Bool
        var memory: Bool
        var display: Bool

        static let empty = Permissions(network: [], location: false, memory: false, display: false)
    }

    struct MCPEntry: Equatable, Sendable {
        let url: String
        /// As written: `none`, `bearer`, `header` — `oauth` decodes so the validator can name it.
        let auth: String
        let header: String?
    }

    struct Parameter: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable, CaseIterable {
            case string, number, integer, boolean
        }
        let name: String
        let kind: Kind
        let description: String?
        let required: Bool
        let maxLength: Int?
        let allowed: [String]?      // `enum`
        let pattern: String?
        let min: Double?
        let max: Double?

        /// The string length cap that applies (declared, or the default 100).
        var effectiveMaxLength: Int { maxLength ?? 100 }
    }

    struct Skill: Equatable, Sendable {
        let name: String
        let description: String
        /// Sorted by name: `parameters` is an object in the file, and object key order is not kept.
        let parameters: [Parameter]
        let steps: [Step]
    }

    // MARK: Steps

    enum Step: Equatable, Sendable {
        case http(HTTPStep)
        case extract(ExtractStep)
        case say(String)
        case remember(RememberStep)
        case display(DisplayStep)
        case when(IfStep)

        var kindName: String {
            switch self {
            case .http: return "http"
            case .extract: return "extract"
            case .say: return "say"
            case .remember: return "remember"
            case .display: return "display"
            case .when: return "if"
            }
        }
    }

    struct HTTPStep: Equatable, Sendable {
        let method: String
        let url: String
        let headers: [String: String]
        let json: JSONValue?
        let form: [String: String]?
        let `as`: String
    }

    struct ExtractStep: Equatable, Sendable {
        let from: String
        let jsonpath: String?
        let regex: String?
        let `as`: String
        let fallback: String?
        let limit: Int?
    }

    struct RememberStep: Equatable, Sendable {
        let key: String
        let value: String
    }

    struct DisplayStep: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable { case text, list, markers }
        struct Marker: Equatable, Sendable {
            let lat: String
            let lon: String
            let label: String
        }
        let kind: String
        let title: String
        let items: [String]?
        let markers: [Marker]?
    }

    struct IfStep: Equatable, Sendable {
        enum Op: String, Equatable, Sendable, CaseIterable {
            case exists, empty, equals, notEquals, greater, less, contains
        }
        let op: String
        let `var`: String
        let value: String?
        let then: [Step]
        let `else`: [Step]
    }

    /// A JSON request body as written: string leaves are templates.
    indirect enum JSONValue: Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])
    }
}

// MARK: - Decode errors

/// Why a file is not the add-on format. `path` is a readable location such as
/// `skills[0].steps[2].http`.
enum RecipeAddOnDecodeError: Error, Equatable, Sendable {
    case unsupportedFormat(String)
    case unknownKey(path: String, key: String)
    case bothSkillsAndMCP
    case neitherSkillsNorMCP
    case invalidStep(path: String, reason: String)
    case malformed(path: String, reason: String)

    var message: String {
        switch self {
        case .unsupportedFormat(let f): return "Unsupported format \"\(f)\"; expected \"\(RecipeAddOnManifest.formatTag)\"."
        case .unknownKey(let path, let key): return "Unknown key \"\(key)\" in \(path.isEmpty ? "the file" : path)."
        case .bothSkillsAndMCP: return "An add-on has either skills or an MCP entry, not both."
        case .neitherSkillsNorMCP: return "An add-on needs skills or an MCP entry."
        case .invalidStep(let path, let reason): return "Step \(path): \(reason)."
        case .malformed(let path, let reason): return "\(path.isEmpty ? "The file" : path): \(reason)."
        }
    }
}

extension RecipeAddOnManifest {

    /// Decode a file. Throws `RecipeAddOnDecodeError` for every refusal, including JSON syntax
    /// and type mismatches (wrapped as `.malformed`).
    static func decode(_ data: Data) throws -> RecipeAddOnManifest {
        do {
            return try JSONDecoder().decode(RecipeAddOnManifest.self, from: data)
        } catch let error as RecipeAddOnDecodeError {
            throw error
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw RecipeAddOnDecodeError.malformed(path: AddOnCodingPath.render(context.codingPath),
                                                   reason: "wrong type")
        } catch let DecodingError.keyNotFound(key, context) {
            throw RecipeAddOnDecodeError.malformed(path: AddOnCodingPath.render(context.codingPath),
                                                   reason: "missing \"\(key.stringValue)\"")
        } catch let DecodingError.dataCorrupted(context) {
            throw RecipeAddOnDecodeError.malformed(path: AddOnCodingPath.render(context.codingPath),
                                                   reason: "not valid JSON")
        } catch {
            throw RecipeAddOnDecodeError.malformed(path: "", reason: "not valid JSON")
        }
    }
}

// MARK: - Strict decoding

struct AddOnAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

enum AddOnCodingPath {
    /// `skills[0].steps[2].http` from a decoder's coding path.
    static func render(_ path: [CodingKey]) -> String {
        var out = ""
        for key in path {
            if let i = key.intValue { out += "[\(i)]" } else { out += out.isEmpty ? key.stringValue : ".\(key.stringValue)" }
        }
        return out
    }
}

private extension Decoder {
    /// A keyed container that has already refused any key outside `allowed`.
    func strictContainer(allowing allowed: Set<String>) throws -> KeyedDecodingContainer<AddOnAnyKey> {
        let container = try self.container(keyedBy: AddOnAnyKey.self)
        // Sorted so the reported key is deterministic when there are several.
        if let unknown = container.allKeys.map(\.stringValue).sorted().first(where: { !allowed.contains($0) }) {
            throw RecipeAddOnDecodeError.unknownKey(path: AddOnCodingPath.render(codingPath), key: unknown)
        }
        return container
    }
}

private extension KeyedDecodingContainer where Key == AddOnAnyKey {
    func req<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T {
        try decode(T.self, forKey: AddOnAnyKey(key))
    }
    func opt<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T? {
        try decodeIfPresent(T.self, forKey: AddOnAnyKey(key))
    }
}

extension RecipeAddOnManifest: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: [
            "format", "id", "name", "version", "author", "description", "icon", "coverage",
            "slow", "minAppBuild", "permissions", "skills", "mcp",
        ])
        format = try c.req("format")
        guard format == Self.formatTag else { throw RecipeAddOnDecodeError.unsupportedFormat(format) }
        id = try c.req("id")
        name = try c.req("name")
        version = try c.req("version")
        author = try c.req("author")
        description = try c.req("description")
        icon = try c.opt("icon")
        coverage = try c.opt("coverage")
        slow = try c.opt("slow") ?? false
        minAppBuild = try c.opt("minAppBuild")
        permissions = try c.opt("permissions") ?? .empty
        let skills: [Skill]? = try c.opt("skills")
        let mcp: MCPEntry? = try c.opt("mcp")
        switch (skills, mcp) {
        case (.some, .some): throw RecipeAddOnDecodeError.bothSkillsAndMCP
        case (.none, .none): throw RecipeAddOnDecodeError.neitherSkillsNorMCP
        case (.some(let s), .none): content = .skills(s)
        case (.none, .some(let m)): content = .mcp(m)
        }
    }
}

extension RecipeAddOnManifest.Author: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["name", "web"])
        name = try c.req("name")
        web = try c.opt("web")
    }
}

extension RecipeAddOnManifest.Permissions: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["network", "location", "memory", "display"])
        network = try c.opt("network") ?? []
        location = try c.opt("location") ?? false
        memory = try c.opt("memory") ?? false
        display = try c.opt("display") ?? false
    }
}

extension RecipeAddOnManifest.MCPEntry: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["url", "auth", "header"])
        url = try c.req("url")
        auth = try c.opt("auth") ?? "none"
        header = try c.opt("header")
    }
}

/// A parameter's body, decoded without its name (the name is its key in `parameters`).
private struct ParameterBody: Decodable {
    let kind: RecipeAddOnManifest.Parameter.Kind
    let description: String?
    let required: Bool
    let maxLength: Int?
    let allowed: [String]?
    let pattern: String?
    let min: Double?
    let max: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: [
            "type", "description", "required", "maxLength", "enum", "pattern", "min", "max",
        ])
        let type: String = try c.req("type")
        guard let kind = RecipeAddOnManifest.Parameter.Kind(rawValue: type) else {
            throw RecipeAddOnDecodeError.malformed(path: AddOnCodingPath.render(decoder.codingPath),
                                                   reason: "type \"\(type)\" is not string, number, integer or boolean")
        }
        self.kind = kind
        description = try c.opt("description")
        required = try c.opt("required") ?? false
        maxLength = try c.opt("maxLength")
        allowed = try c.opt("enum")
        pattern = try c.opt("pattern")
        min = try c.opt("min")
        max = try c.opt("max")
    }
}

extension RecipeAddOnManifest.Skill: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["name", "description", "parameters", "steps"])
        name = try c.req("name")
        description = try c.req("description")
        steps = try c.req("steps")
        if c.contains(AddOnAnyKey("parameters")) {
            let p = try c.nestedContainer(keyedBy: AddOnAnyKey.self, forKey: AddOnAnyKey("parameters"))
            // `allKeys` order is not the file's; sort by name so the schema is deterministic.
            parameters = try p.allKeys.sorted { $0.stringValue < $1.stringValue }.map { key in
                let body = try p.decode(ParameterBody.self, forKey: key)
                return .init(name: key.stringValue, kind: body.kind, description: body.description,
                             required: body.required, maxLength: body.maxLength, allowed: body.allowed,
                             pattern: body.pattern, min: body.min, max: body.max)
            }
        } else {
            parameters = []
        }
    }
}

extension RecipeAddOnManifest.Step: Decodable {
    init(from decoder: Decoder) throws {
        let kinds: Set<String> = ["http", "extract", "say", "remember", "display", "if"]
        let c = try decoder.strictContainer(allowing: kinds)
        guard c.allKeys.count == 1, let key = c.allKeys.first?.stringValue else {
            throw RecipeAddOnDecodeError.invalidStep(path: AddOnCodingPath.render(decoder.codingPath),
                                                     reason: "a step has exactly one of http, extract, say, remember, display or if")
        }
        switch key {
        case "http": self = .http(try c.req(key))
        case "extract": self = .extract(try c.req(key))
        case "say": self = .say(try c.req(key))
        case "remember": self = .remember(try c.req(key))
        case "display": self = .display(try c.req(key))
        default: self = .when(try c.req(key))
        }
    }
}

extension RecipeAddOnManifest.HTTPStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["method", "url", "headers", "json", "form", "as"])
        method = try c.opt("method") ?? "GET"
        url = try c.req("url")
        headers = try c.opt("headers") ?? [:]
        json = try c.opt("json")
        form = try c.opt("form")
        self.as = try c.req("as")
    }
}

extension RecipeAddOnManifest.ExtractStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["from", "jsonpath", "regex", "as", "fallback", "limit"])
        from = try c.req("from")
        jsonpath = try c.opt("jsonpath")
        regex = try c.opt("regex")
        self.as = try c.req("as")
        fallback = try c.opt("fallback")
        limit = try c.opt("limit")
    }
}

extension RecipeAddOnManifest.RememberStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["key", "value"])
        key = try c.req("key")
        value = try c.req("value")
    }
}

extension RecipeAddOnManifest.DisplayStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["kind", "title", "items", "markers"])
        kind = try c.req("kind")
        title = try c.req("title")
        items = try c.opt("items")
        markers = try c.opt("markers")
    }
}

extension RecipeAddOnManifest.DisplayStep.Marker: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["lat", "lon", "label"])
        // A coordinate may be written as a number or as a template string.
        func coordinate(_ key: String) throws -> String {
            if let d = try? c.decode(Double.self, forKey: AddOnAnyKey(key)) { return RecipeJSONPath.numberText(d) }
            return try c.req(key)
        }
        lat = try coordinate("lat")
        lon = try coordinate("lon")
        label = try c.req("label")
    }
}

extension RecipeAddOnManifest.IfStep: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.strictContainer(allowing: ["op", "var", "value", "then", "else"])
        op = try c.req("op")
        self.var = try c.req("var")
        value = try c.opt("value")
        then = try c.opt("then") ?? []
        self.else = try c.opt("else") ?? []
    }
}

extension RecipeAddOnManifest.JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: AddOnAnyKey.self) {
            var object: [String: Self] = [:]
            for key in keyed.allKeys { object[key.stringValue] = try keyed.decode(Self.self, forKey: key) }
            self = .object(object)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [Self] = []
            while !unkeyed.isAtEnd { array.append(try unkeyed.decode(Self.self)) }
            self = .array(array)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let b = try? single.decode(Bool.self) { self = .bool(b) }
        else if let d = try? single.decode(Double.self) { self = .number(d) }
        else { self = .string(try single.decode(String.self)) }
    }
}
