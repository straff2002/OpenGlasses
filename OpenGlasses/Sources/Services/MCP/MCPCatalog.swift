import Foundation

/// A field the user fills to complete a catalogue server's URL — e.g. a Home Assistant host. The
/// `key` is substituted into `MCPCatalogEntry.urlTemplate` as `{key}`.
struct MCPCatalogField: Decodable, Identifiable, Equatable {
    let key: String
    let label: String
    var placeholder: String = ""

    var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, label, placeholder }

    // Explicit decoder: Swift's *synthesized* Decodable ignores a property's default value and
    // demands every key, so `placeholder` must be decoded as optional to keep its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = try c.decode(String.self, forKey: .label)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder) ?? ""
    }
}

/// How a catalogue entry authenticates, with a human hint for the install screen.
struct MCPCatalogAuth: Decodable, Equatable {
    let kind: MCPAuthKind
    var hint: String = ""

    private enum CodingKeys: String, CodingKey { case kind, hint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(MCPAuthKind.self, forKey: .kind)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
    }
}

/// One vetted, one-tap MCP server, decoded from the bundled `mcp-catalog.json`.
///
/// An install renders `fields`, substitutes them into `urlTemplate`, and produces an ordinary
/// [[MCPServerConfig]] that flows through the *exact* discovery → Plan R screen → router path that
/// a hand-added server uses. The catalogue is convenience over the existing primitive, not a new
/// subsystem — one install funnel, one screen, one router (the "single governance path").
struct MCPCatalogEntry: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    let transport: MCPTransportKind
    let urlTemplate: String
    let auth: MCPCatalogAuth
    var fields: [MCPCatalogField] = []
    var scopes: [String] = []
    var icon: String = "puzzlepiece.extension"
    var notes: String = ""

    enum CodingKeys: String, CodingKey {
        case id, label, transport
        case urlTemplate = "url_template"
        case auth, fields, scopes, icon, notes
    }

    // `id`/`label`/`urlTemplate` decode leniently (default ""), so a present-but-empty value is
    // caught and *reported* by `validationError` rather than silently dropped at decode time;
    // `transport`/`auth` are required; the rest keep their defaults (synthesized Decodable can't).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        label       = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        transport   = try c.decode(MCPTransportKind.self, forKey: .transport)
        urlTemplate = try c.decodeIfPresent(String.self, forKey: .urlTemplate) ?? ""
        auth        = try c.decode(MCPCatalogAuth.self, forKey: .auth)
        fields      = try c.decodeIfPresent([MCPCatalogField].self, forKey: .fields) ?? []
        scopes      = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        icon        = try c.decodeIfPresent(String.self, forKey: .icon) ?? "puzzlepiece.extension"
        notes       = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

extension MCPCatalogEntry {
    /// Placeholder keys referenced by `urlTemplate`, e.g. `http://{host}:8123/sse` → `["host"]`.
    var placeholderKeys: [String] {
        Self.placeholderRegex
            .matches(in: urlTemplate, range: NSRange(urlTemplate.startIndex..., in: urlTemplate))
            .compactMap { match in
                guard let range = Range(match.range(at: 1), in: urlTemplate) else { return nil }
                return String(urlTemplate[range])
            }
    }

    /// Fill `urlTemplate` from `values`. Returns `nil` if any placeholder is missing or blank, so a
    /// half-completed install can't produce a broken URL.
    func resolvedURL(from values: [String: String]) -> String? {
        var url = urlTemplate
        for key in placeholderKeys {
            guard let raw = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return nil
            }
            url = url.replacingOccurrences(of: "{\(key)}", with: raw)
        }
        return url
    }

    /// Build the `MCPServerConfig` for a one-tap install. Crucially this defaults the egress policy
    /// to **`.redact`** (never `.allow`): a vetted, convenient install still funnels through the
    /// Plan R outbound screen, and — being an ordinary config — its tools are scanned by
    /// `ToolDefinitionScanner` at discovery. For `bearer`, `token` is prefilled as an `Authorization`
    /// header; `oauth`/`none` leave `headers` empty (OAuth automation is deferred — the user pastes a
    /// token in the editor). Returns `nil` if the URL can't be resolved from `values`.
    func makeServerConfig(values: [String: String] = [:], token: String? = nil) -> MCPServerConfig? {
        guard let url = resolvedURL(from: values) else { return nil }

        var headers: [String: String] = [:]
        if auth.kind == .bearer, let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            headers["Authorization"] = token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
        }

        return MCPServerConfig(
            id: UUID().uuidString,
            label: label,
            url: url,
            headers: headers,
            enabled: true,
            policy: .redact,        // SAFE DEFAULT — one-tap convenience never outruns the Plan R screen.
            transport: transport,
            authKind: auth.kind
        )
    }

    /// Why this entry is unfit to install, or `nil` if it's valid. Used to drop malformed rows so a
    /// single bad entry can't sink the whole catalogue.
    var validationError: String? {
        if id.trimmingCharacters(in: .whitespaces).isEmpty { return "missing id" }
        if label.trimmingCharacters(in: .whitespaces).isEmpty { return "missing label" }
        if urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty { return "missing url_template" }

        // Every placeholder the URL references must have a matching field, or install can never
        // complete it.
        let fieldKeys = Set(fields.map(\.key))
        for key in placeholderKeys where !fieldKeys.contains(key) {
            return "url_template references {\(key)} with no matching field"
        }
        return nil
    }

    private static let placeholderRegex = try! NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)\}"#)
}

/// A loaded, validated catalogue of one-tap MCP servers.
struct MCPCatalog: Equatable {
    let version: Int
    let entries: [MCPCatalogEntry]

    /// Decode + validate a catalogue from JSON `{ "version": Int, "servers": [...] }`. Throws only
    /// if the top-level shape is un-decodable; individual malformed/duplicate entries are dropped
    /// (a bad row shouldn't sink the catalogue). Use `loadStrict` to inspect what was rejected.
    static func load(from data: Data) throws -> MCPCatalog {
        try loadStrict(from: data).catalog
    }

    /// As `load`, additionally returning a human-readable list of rejected entries (for tests/logs).
    static func loadStrict(from data: Data) throws -> (catalog: MCPCatalog, rejected: [String]) {
        let raw = try JSONDecoder().decode(RawCatalog.self, from: data)

        var valid: [MCPCatalogEntry] = []
        var rejected: [String] = []
        var seenIDs = Set<String>()

        for entry in raw.servers {
            if let reason = entry.validationError {
                rejected.append("\(entry.id.isEmpty ? "<no id>" : entry.id): \(reason)")
            } else if !seenIDs.insert(entry.id).inserted {
                rejected.append("\(entry.id): duplicate id")
            } else {
                valid.append(entry)
            }
        }
        return (MCPCatalog(version: raw.version, entries: valid), rejected)
    }

    /// Load the catalogue shipped in the app bundle. Returns `nil` if the resource is absent or
    /// unparseable — callers fall back to the manual "Add" path.
    static func bundled(_ bundle: Bundle = .main) -> MCPCatalog? {
        guard let url = bundle.url(forResource: "mcp-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? load(from: data)
    }

    /// Top-level decoder that tolerates a single malformed `servers` element rather than failing the
    /// whole decode. Each element is decoded through `Throwable`, which captures any per-entry error
    /// (and, critically, always advances the unkeyed container's index so this can't loop).
    private struct RawCatalog: Decodable {
        let version: Int
        let servers: [MCPCatalogEntry]

        enum CodingKeys: String, CodingKey { case version, servers }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1

            var list = try container.nestedUnkeyedContainer(forKey: .servers)
            var parsed: [MCPCatalogEntry] = []
            while !list.isAtEnd {
                let element = try list.decode(Throwable<MCPCatalogEntry>.self)
                if case .success(let entry) = element.result {
                    parsed.append(entry)
                }
            }
            servers = parsed
        }
    }

    /// Wraps a `Decodable` so a failed element decode is captured instead of thrown — letting a
    /// lossy array skip bad rows without aborting the rest.
    private struct Throwable<T: Decodable>: Decodable {
        let result: Result<T, Error>
        init(from decoder: Decoder) throws {
            result = Result { try T(from: decoder) }
        }
    }
}
