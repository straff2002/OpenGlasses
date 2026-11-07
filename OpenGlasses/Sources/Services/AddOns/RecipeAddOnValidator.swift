import Foundation

/// One reason an add-on file is refused. `code` is stable and typed (a sheet or a test switches on
/// it); `path` points into the file (`skills[0].steps[2].http.url`); `detail` is a short
/// developer-facing explanation. Every issue refuses the file — there are no warnings.
struct RecipeAddOnIssue: Equatable, Sendable, CustomStringConvertible {

    enum Code: String, Equatable, Sendable, CaseIterable {
        // The file
        case decodeFailed
        case idInvalid, nameInvalid, versionInvalid, authorNameInvalid, authorWebInvalid
        case descriptionInvalid, iconNotAllowed, coverageInvalid, minAppBuildInvalid
        case definitionScreen
        // Permissions
        case networkEntryInvalid, networkTooManyEntries
        case locationNeedsPermission, rememberNeedsMemory, displayNeedsDisplay
        // Skills and parameters
        case skillCount, skillNameInvalid, skillNameDuplicate, skillDescriptionInvalid
        case tooManyParameters, parameterNameInvalid, parameterShapeInvalid, parameterPatternUnsafe
        // Steps
        case tooManySteps, ifTooDeep, templateInvalid, variableUndefined, outputNameInvalid
        case sayMissingOnSomePath, sayTooLong, tooManyRemembers, tooManyRequests
        case rememberInvalid, displayInvalid, ifInvalid
        case httpMethodInvalid, httpURLInvalid, httpHostTemplated, httpHostNotAllowed
        case httpBodyInvalid, headerInvalid, headerForbidden
        case extractInvalid, jsonPathInvalid, regexUnsafe
        // MCP entries
        case mcpURLInvalid, mcpHostNotAllowed, mcpAuthRefused, mcpAuthInvalid, mcpHeaderInvalid
    }

    let code: Code
    let path: String
    let detail: String

    var description: String { "\(code.rawValue) at \(path.isEmpty ? "<file>" : path): \(detail)" }
}

/// Install-time admission for a recipe add-on. Pure and deterministic.
///
/// Checks every limit in the format: identity fields, the network allowlist (`AddOnDomainRule`),
/// parameter shapes, step counts and nesting, templates and the variables they use (a variable
/// must be defined on **every** path before it is used), a `say` on every path, the permissions
/// each step needs, literal allowlisted hosts in every URL, safe regexes, parseable JSONPaths, and
/// the definition screen (`ToolDefinitionScanner`) over the add-on's and each skill's name and
/// description — anything but `.trusted` refuses the file, as for skill packs.
///
/// Signatures, trust classes and reserved capabilities are not handled here yet; a reserved
/// capability named in `permissions` is an unknown key, which the strict decoder already refuses.
enum RecipeAddOnValidator {

    // MARK: Limits

    static let maxIDLength = 64
    static let maxNameLength = 30
    static let maxDescriptionLength = 240
    static let maxAuthorNameLength = 60
    static let skillRange = 1...10
    static let maxSkillNameLength = 40
    static let maxSkillDescriptionLength = 400
    static let maxParameters = 20
    static let maxParameterNameLength = 32
    static let maxParameterDescriptionLength = 200
    static let maxStringParameterLength = 200
    static let maxEnumValues = 50
    static let maxStepsPerSkill = 40
    static let maxIfDepth = 3
    static let maxSayLength = 500
    static let maxRemembersPerRun = 3
    static let maxRequestsPerRun = RecipeSandbox.maxRequestsPerRun
    static let maxHeaders = 10
    static let maxHeaderValueLength = 500
    static let maxJSONBodyDepth = 5
    static let maxDisplayItems = 10
    static let maxDisplayTitleLength = 60
    static let maxMemoryKeyLength = 40
    static let maxTemplateLength = 2_000

    /// Always defined for a run.
    static let builtIns: Set<String> = ["now", "today", "locale", "units"]
    /// Defined only for an add-on with the `location` permission.
    static let locationBuiltIns: Set<String> = ["lat", "lon", "city", "country"]

    /// The SF Symbols an add-on may show. A small curated static set rather than the whole symbol
    /// catalogue, so an add-on can't borrow the look of a system app or a native feature (no
    /// phone, message, camera, heart or lock glyphs). Add generic symbols here as add-ons need them.
    static let allowedIcons: Set<String> = [
        "dollarsign.arrow.circlepath", "dollarsign.circle", "eurosign.circle", "sterlingsign.circle",
        "yensign.circle", "banknote", "chart.line.uptrend.xyaxis", "chart.bar", "percent", "number",
        "sun.max", "sunrise", "sunset", "moon.stars", "cloud.sun", "cloud.rain", "cloud.bolt",
        "snowflake", "wind", "thermometer.medium", "drop", "humidity", "aqi.medium", "water.waves",
        "leaf", "tree", "mountain.2", "flame", "bolt", "globe", "globe.europe.africa", "map",
        "mappin.and.ellipse", "signpost.right", "tram", "bus", "airplane", "ferry", "car", "bicycle",
        "fork.knife", "cup.and.saucer", "book", "book.closed", "text.book.closed", "newspaper",
        "character.book.closed", "graduationcap", "lightbulb", "puzzlepiece.extension", "sparkles",
        "star", "wrench.and.screwdriver", "hammer", "ruler", "gauge.with.dots.needle.33percent",
        "clock", "hourglass", "timer", "sportscourt", "figure.walk", "pawprint", "music.note",
        "film", "gamecontroller", "questionmark.circle", "info.circle", "exclamationmark.triangle",
        "waveform.path", "antenna.radiowaves.left.and.right", "shippingbox", "tag", "ticket",
    ]

    /// ISO 3166-1 alpha-2 region codes.
    static let regionCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 })

    // MARK: Entry points

    struct Report: Sendable {
        let manifest: RecipeAddOnManifest?
        let issues: [RecipeAddOnIssue]
        var isAccepted: Bool { manifest != nil && issues.isEmpty }
    }

    /// Decode then validate a file. A decode failure is reported as one `.decodeFailed` issue.
    static func validate(data: Data, nativeToolNames: Set<String> = []) -> Report {
        do {
            let manifest = try RecipeAddOnManifest.decode(data)
            return Report(manifest: manifest, issues: validate(manifest, nativeToolNames: nativeToolNames))
        } catch let error as RecipeAddOnDecodeError {
            return Report(manifest: nil, issues: [.init(code: .decodeFailed, path: decodePath(error), detail: error.message)])
        } catch {
            return Report(manifest: nil, issues: [.init(code: .decodeFailed, path: "", detail: "not an add-on file")])
        }
    }

    /// Every issue with a decoded manifest; empty means it may be offered for install.
    /// `nativeToolNames` are the app's own tool names, for the definition screen's collision check.
    static func validate(_ manifest: RecipeAddOnManifest, nativeToolNames: Set<String> = []) -> [RecipeAddOnIssue] {
        var v = Run(manifest: manifest, nativeNames: nativeToolNames)
        v.checkIdentity()
        v.checkNetwork()
        switch manifest.content {
        case .skills(let skills): v.checkSkills(skills)
        case .mcp(let entry): v.checkMCP(entry)
        }
        return v.issues
    }

    private static func decodePath(_ error: RecipeAddOnDecodeError) -> String {
        switch error {
        case .unknownKey(let path, _), .invalidStep(let path, _), .malformed(let path, _): return path
        default: return ""
        }
    }

    // MARK: - The pass

    private struct Run {
        let manifest: RecipeAddOnManifest
        let nativeNames: Set<String>
        var issues: [RecipeAddOnIssue] = []
        var rules: [AddOnDomainRule] = []

        init(manifest: RecipeAddOnManifest, nativeNames: Set<String>) {
            self.manifest = manifest
            self.nativeNames = nativeNames
        }

        mutating func add(_ code: RecipeAddOnIssue.Code, _ path: String, _ detail: String) {
            issues.append(.init(code: code, path: path, detail: detail))
        }

        // MARK: Identity

        mutating func checkIdentity() {
            let m = manifest
            if m.id.count > maxIDLength || !fullMatch(#"^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]+(-[a-z0-9]+)*)+$"#, m.id) {
                add(.idInvalid, "id", "reverse-DNS, lowercase, at least two labels, at most \(maxIDLength) characters")
            }
            if !isCleanLine(m.name, max: maxNameLength) {
                add(.nameInvalid, "name", "1–\(maxNameLength) characters on one line")
            }
            if !fullMatch(#"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, m.version) {
                add(.versionInvalid, "version", "semantic version such as 1.0.0")
            }
            if !isCleanLine(m.author.name, max: maxAuthorNameLength) {
                add(.authorNameInvalid, "author.name", "1–\(maxAuthorNameLength) characters on one line")
            }
            if let web = m.author.web {
                let c = URLComponents(string: web)
                if web.count > 200 || c?.scheme?.lowercased() != "https" || (c?.host ?? "").isEmpty
                    || c?.user != nil || c?.password != nil || web.contains("{{") {
                    add(.authorWebInvalid, "author.web", "an https address")
                }
            }
            if !isCleanText(m.description, max: maxDescriptionLength) {
                add(.descriptionInvalid, "description", "1–\(maxDescriptionLength) characters")
            }
            if let icon = m.icon, !allowedIcons.contains(icon) {
                add(.iconNotAllowed, "icon", "\"\(icon)\" is not in the add-on icon set")
            }
            if let coverage = m.coverage {
                if coverage.isEmpty {
                    add(.coverageInvalid, "coverage", "list region codes or \"*\"")
                } else if coverage.contains("*"), coverage.count > 1 {
                    add(.coverageInvalid, "coverage", "\"*\" must be the only entry")
                } else {
                    for (i, code) in coverage.enumerated() where code != "*" && !regionCodes.contains(code) {
                        add(.coverageInvalid, "coverage[\(i)]", "\"\(code)\" is not an ISO 3166-1 alpha-2 code")
                    }
                }
            }
            if let build = m.minAppBuild, build < 1 {
                add(.minAppBuildInvalid, "minAppBuild", "a positive build number")
            }
            screen(name: m.name, description: m.description, schema: ["type": "object"], path: "")
        }

        // MARK: Network

        mutating func checkNetwork() {
            let parsed = AddOnDomainRule.parseAllowlist(manifest.permissions.network)
            rules = parsed.rules
            if parsed.tooMany {
                add(.networkTooManyEntries, "permissions.network", "at most \(AddOnDomainRule.maxEntries) entries")
            }
            for (entry, error) in parsed.failures {
                let index = manifest.permissions.network.firstIndex(of: entry) ?? 0
                add(.networkEntryInvalid, "permissions.network[\(index)]", "\"\(entry)\": \(error)")
            }
        }

        // MARK: MCP

        mutating func checkMCP(_ entry: RecipeAddOnManifest.MCPEntry) {
            let c = URLComponents(string: entry.url)
            if entry.url.contains("{{") || c?.scheme?.lowercased() != "https" || (c?.host ?? "").isEmpty
                || c?.user != nil || c?.password != nil || c?.port != nil {
                add(.mcpURLInvalid, "mcp.url", "an https address with a literal host and no port")
            } else if let host = c?.host, !AddOnDomainRule.allows(host: host, rules: rules) {
                add(.mcpHostNotAllowed, "mcp.url", "\(host) is not in permissions.network")
            }
            switch entry.auth {
            case "none", "bearer":
                if entry.header != nil { add(.mcpHeaderInvalid, "mcp.header", "only used with auth \"header\"") }
            case "header":
                if let header = entry.header, isHeaderToken(header), !RecipeSandbox.isForbiddenHeader(header) {
                    break
                }
                add(.mcpHeaderInvalid, "mcp.header", "auth \"header\" needs a header name")
            case "oauth":
                add(.mcpAuthRefused, "mcp.auth", "OAuth servers can't be added as add-ons")
            default:
                add(.mcpAuthInvalid, "mcp.auth", "none, bearer or header")
            }
        }

        // MARK: Skills

        mutating func checkSkills(_ skills: [RecipeAddOnManifest.Skill]) {
            if !skillRange.contains(skills.count) {
                add(.skillCount, "skills", "\(skillRange.lowerBound)–\(skillRange.upperBound) skills")
            }
            var seen = Set<String>()
            for (i, skill) in skills.enumerated() {
                let path = "skills[\(i)]"
                if skill.name.count > maxSkillNameLength || !fullMatch(#"^[a-z][a-z0-9_]*$"#, skill.name) {
                    add(.skillNameInvalid, "\(path).name", "lowercase letters, digits and _, starting with a letter, ≤ \(maxSkillNameLength)")
                }
                if !seen.insert(skill.name).inserted {
                    add(.skillNameDuplicate, "\(path).name", "\"\(skill.name)\" is used twice")
                }
                if !isCleanText(skill.description, max: maxSkillDescriptionLength) {
                    add(.skillDescriptionInvalid, "\(path).description", "1–\(maxSkillDescriptionLength) characters")
                }
                checkParameters(skill.parameters, path: "\(path).parameters")
                let screenText = ([skill.description] + skill.parameters.compactMap(\.description)).joined(separator: "\n")
                screen(name: skill.name, description: screenText, schema: skill.inputSchema, path: path)
                checkSteps(of: skill, path: path)
            }
        }

        mutating func checkParameters(_ parameters: [RecipeAddOnManifest.Parameter], path: String) {
            if parameters.count > maxParameters {
                add(.tooManyParameters, path, "at most \(maxParameters) parameters")
            }
            let reserved = builtIns.union(locationBuiltIns)
            for p in parameters {
                let ppath = "\(path).\(p.name)"
                if p.name.count > maxParameterNameLength || p.name.contains(".")
                    || !RecipeTemplate.isValidVariableName(p.name) || reserved.contains(p.name) {
                    add(.parameterNameInvalid, ppath, "a short name (letters, digits, _) that isn't a built-in")
                }
                if let d = p.description, d.count > maxParameterDescriptionLength {
                    add(.parameterShapeInvalid, "\(ppath).description", "at most \(maxParameterDescriptionLength) characters")
                }
                switch p.kind {
                case .string:
                    if p.min != nil || p.max != nil {
                        add(.parameterShapeInvalid, ppath, "min/max are for numbers")
                    }
                    if let n = p.maxLength, !(1...maxStringParameterLength).contains(n) {
                        add(.parameterShapeInvalid, "\(ppath).maxLength", "1–\(maxStringParameterLength)")
                    }
                    if let values = p.allowed {
                        if values.isEmpty || values.count > maxEnumValues
                            || values.contains(where: { $0.isEmpty || $0.count > p.effectiveMaxLength }) {
                            add(.parameterShapeInvalid, "\(ppath).enum", "1–\(maxEnumValues) non-empty values within maxLength")
                        }
                    }
                    if let pattern = p.pattern {
                        let found = RecipeRegex.issues(in: pattern, needsCaptureGroup: false)
                        if !found.isEmpty {
                            add(.parameterPatternUnsafe, "\(ppath).pattern", found.map { "\($0)" }.joined(separator: ", "))
                        }
                    }
                case .number, .integer:
                    if p.maxLength != nil || p.allowed != nil || p.pattern != nil {
                        add(.parameterShapeInvalid, ppath, "maxLength, enum and pattern are for strings")
                    }
                    if let lo = p.min, let hi = p.max, lo > hi {
                        add(.parameterShapeInvalid, ppath, "min is above max")
                    }
                    if [p.min, p.max].contains(where: { $0.map { !$0.isFinite } ?? false }) {
                        add(.parameterShapeInvalid, ppath, "min/max must be finite")
                    }
                case .boolean:
                    if p.maxLength != nil || p.allowed != nil || p.pattern != nil || p.min != nil || p.max != nil {
                        add(.parameterShapeInvalid, ppath, "a boolean takes no limits")
                    }
                }
            }
        }

        // MARK: Steps

        struct Flow {
            var definite: Set<String>
            var maybe: Set<String>
        }

        mutating func checkSteps(of skill: RecipeAddOnManifest.Skill, path: String) {
            let steps = skill.steps
            let count = RecipeStepStats.totalSteps(steps)
            if count > maxStepsPerSkill {
                add(.tooManySteps, "\(path).steps", "\(count) steps; at most \(maxStepsPerSkill), counted through branches")
            }
            if !RecipeStepStats.alwaysSays(steps) {
                add(.sayMissingOnSomePath, "\(path).steps", "every path must end up saying something")
            }
            let remembers = RecipeStepStats.maxOnAnyPath(steps) { if case .remember = $0 { return true }; return false }
            if remembers > maxRemembersPerRun {
                add(.tooManyRemembers, "\(path).steps", "at most \(maxRemembersPerRun) remember steps on any path")
            }
            let requests = RecipeStepStats.maxOnAnyPath(steps) { if case .http = $0 { return true }; return false }
            if requests > maxRequestsPerRun {
                add(.tooManyRequests, "\(path).steps", "at most \(maxRequestsPerRun) requests on any path")
            }
            var defined = builtIns.union(skill.parameters.map(\.name))
            if manifest.permissions.location { defined.formUnion(locationBuiltIns) }
            var flow = Flow(definite: defined, maybe: [])
            walk(steps, path: "\(path).steps", flow: &flow, depth: 0)
        }

        mutating func walk(_ steps: [RecipeAddOnManifest.Step], path: String, flow: inout Flow, depth: Int) {
            for (i, step) in steps.enumerated() {
                let spath = "\(path)[\(i)].\(step.kindName)"
                switch step {
                case .http(let h): checkHTTP(h, path: spath, flow: &flow)
                case .extract(let e): checkExtract(e, path: spath, flow: &flow)
                case .say(let text):
                    if text.count > maxSayLength {
                        add(.sayTooLong, spath, "at most \(maxSayLength) characters")
                    }
                    use(text, path: spath, flow: flow)
                case .remember(let r):
                    if !manifest.permissions.memory {
                        add(.rememberNeedsMemory, spath, "remember needs the memory permission")
                    }
                    if r.key.count > maxMemoryKeyLength || !fullMatch(#"^[a-z0-9][a-z0-9_.-]*$"#, r.key) {
                        add(.rememberInvalid, "\(spath).key", "a literal key: lowercase letters, digits, _ . -, ≤ \(maxMemoryKeyLength)")
                    }
                    if r.value.count > maxSayLength {
                        add(.rememberInvalid, "\(spath).value", "at most \(maxSayLength) characters")
                    }
                    use(r.value, path: "\(spath).value", flow: flow)
                case .display(let d): checkDisplay(d, path: spath, flow: flow)
                case .when(let w):
                    if depth + 1 > maxIfDepth {
                        add(.ifTooDeep, spath, "if steps nest at most \(maxIfDepth) deep")
                    }
                    checkIf(w, path: spath, flow: &flow, depth: depth + 1)
                }
            }
        }

        mutating func checkHTTP(_ h: RecipeAddOnManifest.HTTPStep, path: String, flow: inout Flow) {
            let method = h.method.uppercased()
            if method != "GET" && method != "POST" {
                add(.httpMethodInvalid, "\(path).method", "GET or POST")
            }
            if let template = use(h.url, path: "\(path).url", flow: flow) {
                if template.placesVariableBeforePath {
                    add(.httpHostTemplated, "\(path).url", "the scheme and host must be written out, not templated")
                } else {
                    let sample = template.renderURL(Dictionary(uniqueKeysWithValues: template.variableNames.map { ($0, "x") }))
                    let c = URLComponents(string: sample)
                    if h.url.count > maxTemplateLength || c?.scheme?.lowercased() != "https" || (c?.host ?? "").isEmpty
                        || c?.user != nil || c?.password != nil || c?.port != nil {
                        add(.httpURLInvalid, "\(path).url", "an https address with no port or user")
                    } else if let host = c?.host, !AddOnDomainRule.allows(host: host, rules: rules) {
                        add(.httpHostNotAllowed, "\(path).url", "\(host) is not in permissions.network")
                    }
                }
            }
            if h.headers.count > maxHeaders {
                add(.headerInvalid, "\(path).headers", "at most \(maxHeaders) headers")
            }
            for (name, value) in h.headers.sorted(by: { $0.key < $1.key }) {
                let hpath = "\(path).headers.\(name)"
                if !isHeaderToken(name) {
                    add(.headerInvalid, hpath, "not a header name")
                } else if RecipeSandbox.isForbiddenHeader(name) {
                    add(.headerForbidden, hpath, "\(name) is set by the app")
                }
                if value.count > maxHeaderValueLength {
                    add(.headerInvalid, hpath, "at most \(maxHeaderValueLength) characters")
                }
                use(value, path: hpath, flow: flow)
            }
            if h.json != nil, h.form != nil {
                add(.httpBodyInvalid, path, "json or form, not both")
            }
            if method != "POST", h.json != nil || h.form != nil {
                add(.httpBodyInvalid, path, "only a POST has a body")
            }
            if let json = h.json {
                if json.depth > maxJSONBodyDepth {
                    add(.httpBodyInvalid, "\(path).json", "nested at most \(maxJSONBodyDepth) deep")
                }
                for leaf in json.stringLeaves { use(leaf, path: "\(path).json", flow: flow) }
            }
            for (_, value) in (h.form ?? [:]).sorted(by: { $0.key < $1.key }) {
                use(value, path: "\(path).form", flow: flow)
            }
            define(h.as, path: "\(path).as", flow: &flow, outputs: RecipeRunner.httpOutputs(h.as))
        }

        mutating func checkExtract(_ e: RecipeAddOnManifest.ExtractStep, path: String, flow: inout Flow) {
            if !RecipeTemplate.isValidVariableName(e.from) || !flow.definite.contains(e.from) {
                add(.variableUndefined, "\(path).from", "\"\(e.from)\" is not defined on every path before this step")
            }
            switch (e.jsonpath, e.regex) {
            case (.some(let jp), .none):
                if let template = use(jp, path: "\(path).jsonpath", flow: flow),
                   case .failure(let error) = RecipeJSONPath.parse(template: template) {
                    add(.jsonPathInvalid, "\(path).jsonpath", "\(error)")
                }
            case (.none, .some(let rx)):
                let found = RecipeRegex.issues(in: rx, needsCaptureGroup: true)
                if !found.isEmpty {
                    add(.regexUnsafe, "\(path).regex", found.map { "\($0)" }.joined(separator: ", "))
                }
            default:
                add(.extractInvalid, path, "exactly one of jsonpath or regex")
            }
            if let limit = e.limit, !(1...RecipeJSONPath.maxResults).contains(limit) {
                add(.extractInvalid, "\(path).limit", "1–\(RecipeJSONPath.maxResults)")
            }
            if let fallback = e.fallback { use(fallback, path: "\(path).fallback", flow: flow) }
            define(e.as, path: "\(path).as", flow: &flow, outputs: [e.as])
        }

        mutating func checkDisplay(_ d: RecipeAddOnManifest.DisplayStep, path: String, flow: Flow) {
            if !manifest.permissions.display {
                add(.displayNeedsDisplay, path, "display needs the display permission")
            }
            if d.title.count > maxDisplayTitleLength {
                add(.displayInvalid, "\(path).title", "at most \(maxDisplayTitleLength) characters")
            }
            use(d.title, path: "\(path).title", flow: flow)
            let items = d.items ?? []
            let markers = d.markers ?? []
            switch RecipeAddOnManifest.DisplayStep.Kind(rawValue: d.kind) {
            case .text:
                if items.count != 1 || d.markers != nil { add(.displayInvalid, path, "a text card has one item") }
            case .list:
                if !(1...maxDisplayItems).contains(items.count) || d.markers != nil {
                    add(.displayInvalid, path, "a list has 1–\(maxDisplayItems) items")
                }
            case .markers:
                if !(1...maxDisplayItems).contains(markers.count) || d.items != nil {
                    add(.displayInvalid, path, "a map has 1–\(maxDisplayItems) markers")
                }
            case nil:
                add(.displayInvalid, "\(path).kind", "text, list or markers")
            }
            for item in items {
                if item.count > maxSayLength { add(.displayInvalid, "\(path).items", "an item is at most \(maxSayLength) characters") }
                use(item, path: "\(path).items", flow: flow)
            }
            for marker in markers {
                use(marker.lat, path: "\(path).markers", flow: flow)
                use(marker.lon, path: "\(path).markers", flow: flow)
                use(marker.label, path: "\(path).markers", flow: flow)
            }
        }

        mutating func checkIf(_ w: RecipeAddOnManifest.IfStep, path: String, flow: inout Flow, depth: Int) {
            let op = RecipeAddOnManifest.IfStep.Op(rawValue: w.op)
            if op == nil {
                add(.ifInvalid, "\(path).op", "exists, empty, equals, notEquals, greater, less or contains")
            }
            if op == .exists {
                // `exists` asks whether a variable was set, so it may name one set on only some paths.
                if !flow.definite.contains(w.var) && !flow.maybe.contains(w.var) {
                    add(.variableUndefined, "\(path).var", "\"\(w.var)\" is never set before this step")
                }
            } else if !flow.definite.contains(w.var) {
                if locationBuiltIns.contains(w.var) && !manifest.permissions.location {
                    add(.locationNeedsPermission, "\(path).var", "{{\(w.var)}} needs the location permission")
                } else {
                    add(.variableUndefined, "\(path).var", "\"\(w.var)\" is not defined on every path before this step")
                }
            }
            let needsValue = op != .exists && op != .empty
            if needsValue, w.value == nil {
                add(.ifInvalid, "\(path).value", "\(w.op) compares against a value")
            } else if !needsValue, op != nil, w.value != nil {
                add(.ifInvalid, "\(path).value", "\(w.op) takes no value")
            }
            if let value = w.value { use(value, path: "\(path).value", flow: flow) }

            var thenFlow = flow
            if op == .exists { thenFlow.definite.insert(w.var) }
            var elseFlow = flow
            walk(w.then, path: "\(path).then", flow: &thenFlow, depth: depth)
            walk(w.else, path: "\(path).else", flow: &elseFlow, depth: depth)
            let definite = thenFlow.definite.intersection(elseFlow.definite)
            let anywhere = thenFlow.definite.union(elseFlow.definite).union(thenFlow.maybe).union(elseFlow.maybe)
            flow = Flow(definite: definite, maybe: anywhere.subtracting(definite))
        }

        // MARK: Helpers

        /// Parse `text` as a template and check every variable it uses is defined. Returns the
        /// template when it parses.
        @discardableResult
        mutating func use(_ text: String, path: String, flow: Flow) -> RecipeTemplate? {
            guard text.count <= maxTemplateLength else {
                add(.templateInvalid, path, "at most \(maxTemplateLength) characters")
                return nil
            }
            switch RecipeTemplate.parse(text) {
            case .failure(let error):
                add(.templateInvalid, path, "\(error)")
                return nil
            case .success(let template):
                for name in template.variableNames where !flow.definite.contains(name) {
                    if locationBuiltIns.contains(name) && !manifest.permissions.location {
                        add(.locationNeedsPermission, path, "{{\(name)}} needs the location permission")
                    } else {
                        add(.variableUndefined, path, "{{\(name)}} is not defined on every path before this step")
                    }
                }
                return template
            }
        }

        mutating func define(_ name: String, path: String, flow: inout Flow, outputs: [String]) {
            let reserved = builtIns.union(locationBuiltIns)
            if name.contains(".") || !RecipeTemplate.isValidVariableName(name) || reserved.contains(name) {
                add(.outputNameInvalid, path, "\"\(name)\" must be a plain name that isn't a built-in")
            }
            flow.definite.formUnion(outputs)
            flow.maybe.subtract(outputs)
        }

        mutating func screen(name: String, description: String, schema: [String: Any], path: String) {
            let verdict = ToolDefinitionScanner.scan(name: name, description: description,
                                                     inputSchema: schema, nativeNames: nativeNames)
            if verdict != .trusted {
                add(.definitionScreen, path, verdict.reason)
            }
        }
    }

    // MARK: - Text checks

    static func fullMatch(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [.anchored], range: range)?.range == range
    }

    /// Non-empty after trimming, within `max`, no control characters at all.
    static func isCleanLine(_ text: String, max: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && text.count <= max
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Non-empty after trimming, within `max`; newlines allowed, other control characters not.
    static func isCleanText(_ text: String, max: Int) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && text.count <= max
            && !text.unicodeScalars.contains { $0 != "\n" && CharacterSet.controlCharacters.contains($0) }
    }

    /// An RFC 9110 token, ≤ 64 characters.
    static func isHeaderToken(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Static step facts

/// Counts over a step tree, shared by the validator and the runner's own caps.
enum RecipeStepStats {

    /// Every step, an `if` and everything inside both its branches included.
    static func totalSteps(_ steps: [RecipeAddOnManifest.Step]) -> Int {
        steps.reduce(0) { sum, step in
            if case .when(let w) = step { return sum + 1 + totalSteps(w.then) + totalSteps(w.else) }
            return sum + 1
        }
    }

    /// Whether every path through `steps` reaches a `say`.
    static func alwaysSays(_ steps: [RecipeAddOnManifest.Step]) -> Bool {
        steps.contains { step in
            switch step {
            case .say: return true
            case .when(let w): return alwaysSays(w.then) && alwaysSays(w.else)
            default: return false
            }
        }
    }

    /// The most steps matching `predicate` on any single path.
    static func maxOnAnyPath(_ steps: [RecipeAddOnManifest.Step],
                             where predicate: (RecipeAddOnManifest.Step) -> Bool) -> Int {
        steps.reduce(0) { sum, step in
            if case .when(let w) = step {
                return sum + max(maxOnAnyPath(w.then, where: predicate), maxOnAnyPath(w.else, where: predicate))
            }
            return sum + (predicate(step) ? 1 : 0)
        }
    }
}

// MARK: - Schema and body helpers

extension RecipeAddOnManifest.Skill {
    /// The JSON Schema the model sees for this skill's parameters.
    var inputSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for p in parameters {
            var entry: [String: Any] = ["type": p.kind.rawValue]
            if let d = p.description { entry["description"] = d }
            switch p.kind {
            case .string:
                entry["maxLength"] = p.effectiveMaxLength
                if let e = p.allowed { entry["enum"] = e }
                if let pattern = p.pattern { entry["pattern"] = pattern }
            case .number, .integer:
                if let lo = p.min { entry["minimum"] = lo }
                if let hi = p.max { entry["maximum"] = hi }
            case .boolean:
                break
            }
            properties[p.name] = entry
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty { schema["required"] = required }
        return schema
    }
}

extension RecipeAddOnManifest.JSONValue {
    var depth: Int {
        switch self {
        case .array(let a): return 1 + (a.map(\.depth).max() ?? 0)
        case .object(let o): return 1 + (o.values.map(\.depth).max() ?? 0)
        default: return 0
        }
    }

    var stringLeaves: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap(\.stringLeaves)
        case .object(let o): return o.keys.sorted().flatMap { o[$0]?.stringLeaves ?? [] }
        default: return []
        }
    }
}
