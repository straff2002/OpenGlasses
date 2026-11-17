import Foundation

/// Recomputes a drafted add-on's permissions from its steps, so the permissions on the sheet are
/// the least the steps need — enforced, never taken from the draft. Pure.
///
/// - `network` is exactly the literal hosts written in the `http` steps' URLs. A URL whose scheme
///   or host is a variable is refused: the wearer approves named domains, and a templated host
///   could be anything at run time.
/// - `location` only when a step uses `{{lat}}`, `{{lon}}`, `{{city}}` or `{{country}}`.
/// - `memory` only with a `remember` step; `display` only with a `display` step.
/// - No reserved capability: a self-built add-on is unsigned, so it could never hold one.
///
/// Whatever the draft declared beyond that is removed, and anything missing is added; the
/// outcome says which, for the test trace and the repair prompt.
enum PermissionMinimizer {

    enum Refusal: Error, Equatable, Sendable {
        /// The scheme or host of an `http` URL is a variable.
        case templatedHost(path: String)
        /// An `http` URL is not a plain https address with a host and no port or user.
        case invalidURL(path: String)
        /// The add-on calls no service at all, so there is nothing for it to look up.
        case noService
        /// An MCP entry rather than skills: the assistant only builds step-by-step skills.
        case notARecipe

        /// One line for the repair prompt.
        var detail: String {
            switch self {
            case .templatedHost(let path):
                return "\(path): the scheme and host must be written out literally, not filled from a variable"
            case .invalidURL(let path):
                return "\(path): use a plain https address with a host and no port or user name"
            case .noService:
                return "the add-on must call a public HTTPS service with an http step"
            case .notARecipe:
                return "build skills with steps; an MCP entry is not allowed"
            }
        }
    }

    struct Outcome: Equatable, Sendable {
        let permissions: RecipeAddOnManifest.Permissions
        /// Declared hosts the steps don't use.
        let removedDomains: [String]
        /// Hosts the steps use that weren't declared.
        let addedDomains: [String]
        /// `location`, `memory`, `display` or a reserved capability declared without a step that
        /// needs it.
        let removedPermissions: [String]
        /// A permission a step needs that wasn't declared.
        let addedPermissions: [String]

        var changedAnything: Bool {
            !removedDomains.isEmpty || !addedDomains.isEmpty || !removedPermissions.isEmpty || !addedPermissions.isEmpty
        }
    }

    static func minimise(_ manifest: RecipeAddOnManifest) -> Result<Outcome, Refusal> {
        guard case .skills(let skills) = manifest.content else { return .failure(.notARecipe) }
        var walk = Walk()
        for (i, skill) in skills.enumerated() {
            if let refusal = walk.visit(skill.steps, path: "skills[\(i)].steps") { return .failure(refusal) }
        }
        guard !walk.hosts.isEmpty else { return .failure(.noService) }

        let network = walk.hosts.sorted()
        let usesLocation = !walk.variables.isDisjoint(with: RecipeAddOnValidator.locationBuiltIns)
        let computed = RecipeAddOnManifest.Permissions(network: network, location: usesLocation,
                                                       memory: walk.remembers, display: walk.displays)

        let declared = manifest.permissions
        let declaredHosts = Set(declared.network.map { normalised($0) ?? $0.lowercased() })
        let removedDomains = declaredHosts.subtracting(network).sorted()
        let addedDomains = Set(network).subtracting(declaredHosts).sorted()
        var removed: [String] = []
        var added: [String] = []
        for (name, was, now) in [("location", declared.location, usesLocation),
                                 ("memory", declared.memory, walk.remembers),
                                 ("display", declared.display, walk.displays)] {
            if was && !now { removed.append(name) }
            if !was && now { added.append(name) }
        }
        removed += AddOnReservedCapability.allCases.filter { declared.reserved.contains($0) }.map(\.rawValue)
        return .success(Outcome(permissions: computed, removedDomains: removedDomains, addedDomains: addedDomains,
                                removedPermissions: removed, addedPermissions: added))
    }

    /// The permissions as the file writes them.
    static func jsonObject(_ permissions: RecipeAddOnManifest.Permissions) -> [String: Any] {
        var out: [String: Any] = [:]
        if !permissions.network.isEmpty { out["network"] = permissions.network }
        if permissions.location { out["location"] = true }
        if permissions.memory { out["memory"] = true }
        if permissions.display { out["display"] = true }
        return out
    }

    static func normalised(_ host: String) -> String? {
        AddOnDomainRule.normalisedHost(host)
    }

    // MARK: - Walk

    private struct Walk {
        var hosts = Set<String>()
        var variables = Set<String>()
        var remembers = false
        var displays = false

        mutating func visit(_ steps: [RecipeAddOnManifest.Step], path: String) -> Refusal? {
            for (j, step) in steps.enumerated() {
                let spath = "\(path)[\(j)]"
                switch step {
                case .http(let h):
                    if let refusal = host(of: h.url, path: "\(spath).http.url") { return refusal }
                    note(h.url)
                    h.headers.values.forEach { note($0) }
                    h.form?.values.forEach { note($0) }
                    if let json = h.json { noteJSON(json) }
                case .extract(let e):
                    variables.insert(e.from)
                    if let jsonpath = e.jsonpath { note(jsonpath) }
                    if let fallback = e.fallback { note(fallback) }
                case .say(let text):
                    note(text)
                case .remember(let r):
                    remembers = true
                    note(r.value)
                case .display(let d):
                    displays = true
                    note(d.title)
                    d.items?.forEach { note($0) }
                    d.markers?.forEach { note($0.lat); note($0.lon); note($0.label) }
                case .when(let w):
                    variables.insert(w.var)
                    if let value = w.value { note(value) }
                    if let refusal = visit(w.then, path: "\(spath).if.then") { return refusal }
                    if let refusal = visit(w.else, path: "\(spath).if.else") { return refusal }
                }
            }
            return nil
        }

        private mutating func host(of url: String, path: String) -> Refusal? {
            guard case .success(let template) = RecipeTemplate.parse(url) else { return .invalidURL(path: path) }
            if template.placesVariableBeforePath { return .templatedHost(path: path) }
            let sample = template.renderURL(Dictionary(uniqueKeysWithValues: template.variableNames.map { ($0, "x") }))
            guard let parts = URLComponents(string: sample), parts.scheme?.lowercased() == "https",
                  let raw = parts.host, !raw.isEmpty, parts.user == nil, parts.password == nil,
                  parts.port == nil,
                  let host = PermissionMinimizer.normalised(raw) else {
                return .invalidURL(path: path)
            }
            hosts.insert(host)
            return nil
        }

        private mutating func note(_ text: String) {
            if case .success(let template) = RecipeTemplate.parse(text) {
                variables.formUnion(template.variableNames)
            }
        }

        private mutating func noteJSON(_ value: RecipeAddOnManifest.JSONValue) {
            switch value {
            case .string(let s): note(s)
            case .array(let items): items.forEach { noteJSON($0) }
            case .object(let fields): fields.values.forEach { noteJSON($0) }
            case .number, .bool, .null: break
            }
        }
    }
}
