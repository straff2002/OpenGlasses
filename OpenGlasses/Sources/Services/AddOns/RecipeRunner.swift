import Foundation

/// What a run knows about the wearer's moment: the built-in variables come from here.
struct RecipeRunContext: Sendable {
    enum Units: String, Sendable { case metric, imperial }

    var now: Date
    var timeZone: TimeZone
    var locale: Locale
    var units: Units
    /// Only read for an add-on with the `location` permission.
    var location: RecipeLocation?
}

struct RecipeLocation: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var city: String?
    var country: String?
}

/// A memory write a run asks for. The runner never touches a store: the caller decides whether
/// and how to write it (under the add-on's namespace), so add-ons can never read memory back.
struct RecipeMemoryWrite: Equatable, Sendable {
    let key: String
    let value: String
}

/// A card a run asks to show. Speech never depends on it.
struct RecipeDisplayPayload: Equatable, Sendable {
    struct Marker: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let label: String
    }
    let kind: RecipeAddOnManifest.DisplayStep.Kind
    let title: String
    let items: [String]
    let markers: [Marker]
}

struct RecipeRunResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case completed
        /// The 30-second run budget ran out; what was said before then is kept.
        case timedOut
        case unknownSkill
        /// The model's arguments don't fit the skill's declared parameters.
        case invalidArguments(String)
        /// A parameter carried a credential (names of the patterns that fired). Nothing was sent.
        case blockedCredential([String])
    }

    let toolName: String
    let outcome: Outcome
    /// What the skill said, raw. Hand the model `wrappedForModel`, never this.
    let spokenText: String
    let memoryWrites: [RecipeMemoryWrite]
    let display: RecipeDisplayPayload?
    let requestsMade: Int

    /// `spokenText` framed as untrusted tool output (`PromptInjectionPolicy`): responses reach the
    /// model only as data.
    var wrappedForModel: String { PromptInjectionPolicy.wrap(toolName: toolName, content: spokenText) }
}

/// Executes one skill of a recipe add-on: `http`, `extract`, `say`, `remember`, `display` and
/// `if` steps over a flat namespace of string variables, inside `RecipeSandbox`.
///
/// Pure apart from the injected transport and clock. Callers validate the file first
/// (`RecipeAddOnValidator`); the runner still enforces the sandbox, the permissions and its own
/// caps whatever it is handed. Failure is data: an `http` step that fails sets `<as>.error`, an
/// `extract` that misses sets its fallback, and nothing here throws.
struct RecipeRunner: Sendable {

    let transport: any AddOnHTTPTransport
    let clock: any AddOnClock
    /// Wall-clock seconds one regex match may take before it counts as a miss.
    var regexBudget: TimeInterval = 1
    /// The most text a run returns (several `say` steps are joined with a space).
    static let maxSpokenLength = 1_000
    static let maxExtractedLength = 2_000

    init(transport: any AddOnHTTPTransport, clock: any AddOnClock = SystemAddOnClock()) {
        self.transport = transport
        self.clock = clock
    }

    /// The tool name a skill is offered under: `addon_<id>_<skill>`, non-alphanumerics as `_`.
    static func toolName(addOnID: String, skill: String) -> String {
        let id = String(addOnID.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return "addon_\(id)_\(skill)"
    }

    /// The variables an `http` step named `name` sets.
    static func httpOutputs(_ name: String) -> [String] {
        [name, "\(name).status", "\(name).ok", "\(name).error"]
    }

    // MARK: - Run

    func run(_ manifest: RecipeAddOnManifest, skill skillName: String, arguments: [String: Any],
             context: RecipeRunContext) async -> RecipeRunResult {
        await perform(manifest, skill: skillName, arguments: arguments, context: context,
                      screen: RecipeArguments.screen, tracing: false).result
    }

    /// One test run of a drafted add-on, the way the assistant tests one it built before the
    /// wearer approves it. The same engine, sandbox and transport as `run`, with three differences:
    /// - the sample values are screened strictly: any `EgressScreen` hit, a credential or personal
    ///   data, blocks the test, and so does a value that contains something the wearer has told the
    ///   assistant (`wearerFacts`), so a test never carries the wearer's own details anywhere;
    /// - `remember` steps are recorded in the trace and never handed to anything that writes, and
    ///   `display` steps are a preview in the trace only;
    /// - every step is traced (`DryRunTrace`).
    /// Location, when the add-on uses it, is the coarse value as in every run.
    func dryRun(_ manifest: RecipeAddOnManifest, skill skillName: String, arguments: [String: Any],
                context: RecipeRunContext, wearerFacts: [String] = []) async -> DryRunTrace {
        let started = clock.now()
        let facts = wearerFacts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= Self.minimumFactLength }
        let strict: ([String: String]) -> RecipeArguments.ScreenOutcome = { values in
            let verdict = EgressScreen.evaluate(values, policy: .block)
            if !verdict.hits.isEmpty { return .blocked(verdict.hits) }
            let matchesFact = values.values.contains { value in
                let lowered = value.lowercased()
                return facts.contains { lowered.contains($0) }
            }
            return matchesFact ? .blocked(["wearer_fact"]) : .passed(values)
        }
        let (result, steps, hosts) = await perform(manifest, skill: skillName, arguments: arguments,
                                                   context: context, screen: strict, tracing: true)
        let outcome: DryRunTrace.Outcome
        switch result.outcome {
        case .completed: outcome = .completed
        case .timedOut: outcome = .timedOut
        case .unknownSkill: outcome = .unknownSkill
        case .invalidArguments(let why): outcome = .invalidArguments(why)
        case .blockedCredential(let hits): outcome = .blockedSample(hits)
        }
        return DryRunTrace(skill: skillName, outcome: outcome, steps: steps, spoken: result.spokenText,
                           requestsMade: result.requestsMade, hostsContacted: hosts,
                           elapsed: max(0, clock.now().timeIntervalSince(started)))
    }

    /// A stored fact shorter than this is too common a string to mean anything in a sample.
    static let minimumFactLength = 4

    private func perform(_ manifest: RecipeAddOnManifest, skill skillName: String, arguments: [String: Any],
                         context: RecipeRunContext,
                         screen: ([String: String]) -> RecipeArguments.ScreenOutcome,
                         tracing: Bool) async -> (result: RecipeRunResult, steps: [DryRunTrace.Step], hosts: [String]) {
        let toolName = Self.toolName(addOnID: manifest.id, skill: skillName)
        func finish(_ outcome: RecipeRunResult.Outcome, _ state: State? = nil)
            -> (result: RecipeRunResult, steps: [DryRunTrace.Step], hosts: [String]) {
            let result = RecipeRunResult(toolName: toolName, outcome: outcome,
                                         spokenText: state.map { String($0.said.joined(separator: " ").prefix(Self.maxSpokenLength)) } ?? "",
                                         memoryWrites: state?.memory ?? [], display: state?.display,
                                         requestsMade: state?.sandbox.requestsMade ?? 0)
            return (result, state?.trace ?? [], state?.hosts ?? [])
        }

        guard let skill = manifest.skills.first(where: { $0.name == skillName }) else { return finish(.unknownSkill) }

        let values: [String: String]
        switch RecipeArguments.check(arguments, against: skill.parameters, regexBudget: regexBudget) {
        case .failure(let reason): return finish(.invalidArguments(reason.message))
        case .success(let checked): values = checked
        }

        // Parameter values pass the egress screen before anything is substituted anywhere.
        let screened: [String: String]
        switch screen(values) {
        case .blocked(let hits): return finish(.blockedCredential(hits))
        case .passed(let safe): screened = safe
        }

        var state = State(sandbox: RecipeSandbox(
            rules: AddOnDomainRule.parseAllowlist(manifest.permissions.network).rules,
            transport: transport, clock: clock))
        state.vars = screened.merging(Self.builtIns(context, permissions: manifest.permissions)) { _, builtIn in builtIn }
        state.permissions = manifest.permissions
        state.tracing = tracing

        await execute(skill.steps, state: &state, depth: 0, path: "steps")
        return finish(state.timedOut ? .timedOut : .completed, state)
    }

    // MARK: - Built-ins

    static func builtIns(_ context: RecipeRunContext, permissions: RecipeAddOnManifest.Permissions) -> [String: String] {
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = context.timeZone
        stamp.formatOptions = [.withInternetDateTime]
        let day = ISO8601DateFormatter()
        day.timeZone = context.timeZone
        day.formatOptions = [.withFullDate]
        var out: [String: String] = [
            "now": stamp.string(from: context.now),
            "today": day.string(from: context.now),
            "locale": context.locale.identifier(.bcp47),
            "units": context.units.rawValue,
        ]
        if permissions.location, let place = context.location {
            out["lat"] = coarse(place.latitude)
            out["lon"] = coarse(place.longitude)
            out["city"] = place.city ?? ""
            out["country"] = place.country ?? ""
        }
        return out
    }

    /// Two decimal places (about 1 km), always with a `.` decimal point.
    static func coarse(_ degrees: Double) -> String {
        guard degrees.isFinite else { return "" }
        let rounded = (degrees * 100).rounded() / 100
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded == 0 ? 0 : rounded)
    }

    // MARK: - Steps

    private struct State {
        var sandbox: RecipeSandbox
        var vars: [String: String] = [:]
        var permissions: RecipeAddOnManifest.Permissions = .empty
        var said: [String] = []
        var memory: [RecipeMemoryWrite] = []
        var display: RecipeDisplayPayload?
        var timedOut = false
        var stepsRun = 0
        /// Only for a test run (`dryRun`).
        var tracing = false
        var trace: [DryRunTrace.Step] = []
        var hosts: [String] = []

        mutating func record(_ step: DryRunTrace.Step) {
            guard tracing else { return }
            trace.append(step)
        }
    }

    private func execute(_ steps: [RecipeAddOnManifest.Step], state: inout State, depth: Int, path: String) async {
        for (index, step) in steps.enumerated() {
            let stepPath = "\(path)[\(index)]"
            if state.timedOut { return }
            if state.sandbox.isOutOfTime { state.timedOut = true; return }
            // Belt and braces for an unvalidated file: the same caps the validator applies.
            state.stepsRun += 1
            if state.stepsRun > RecipeAddOnValidator.maxStepsPerSkill { return }

            switch step {
            case .http(let h):
                await runHTTP(h, state: &state, path: stepPath)
            case .extract(let e):
                runExtract(e, state: &state, path: stepPath)
            case .say(let text):
                let spoken = String(render(text, state.vars, .plain).prefix(RecipeAddOnValidator.maxSayLength))
                if !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.said.append(spoken) }
                state.record(.init(path: stepPath, kind: .say, status: .ok, value: DryRunTrace.truncated(spoken)))
            case .remember(let r):
                guard state.permissions.memory, state.memory.count < RecipeAddOnValidator.maxRemembersPerRun else { break }
                let value = String(render(r.value, state.vars, .plain).prefix(RecipeAddOnValidator.maxSayLength))
                // A test run's writes stay in its trace: `dryRun` never returns them to a writer.
                if state.tracing {
                    state.record(.init(path: stepPath, kind: .remember, status: .simulated, value: r.key))
                } else {
                    state.memory.append(RecipeMemoryWrite(key: r.key, value: value))
                }
            case .display(let d):
                guard state.permissions.display else { break }
                let payload = displayPayload(d, state.vars)
                if state.tracing {
                    state.record(.init(path: stepPath, kind: .display, status: .previewOnly,
                                       value: payload.map { DryRunTrace.truncated($0.title) }))
                } else {
                    state.display = payload ?? state.display
                }
            case .when(let w):
                guard depth < RecipeAddOnValidator.maxIfDepth else { return }
                let takesThen = Self.evaluate(w, vars: state.vars)
                state.record(.init(path: stepPath, kind: .branch, status: .ok, value: takesThen ? "then" : "else"))
                await execute(takesThen ? w.then : w.else, state: &state, depth: depth + 1,
                              path: "\(stepPath).\(takesThen ? "then" : "else")")
            }
        }
    }

    private func runHTTP(_ h: RecipeAddOnManifest.HTTPStep, state: inout State, path: String) async {
        let url: String
        switch RecipeTemplate.parse(h.url) {
        case .success(let t): url = t.renderURL(state.vars)
        case .failure: url = ""
        }
        let headers = h.headers.mapValues { render($0, state.vars, .headerValue) }
        var body: Data?
        var contentType: String?
        if h.method.uppercased() == "POST" {
            if let json = h.json {
                body = Data(Self.serialise(json, state.vars).utf8)
                contentType = "application/json"
            } else if let form = h.form {
                body = Data(form.keys.sorted().map { key in
                    RecipeTemplate.escape(key, for: .formValue) + "=" + render(form[key] ?? "", state.vars, .formValue)
                }.joined(separator: "&").utf8)
                contentType = "application/x-www-form-urlencoded"
            }
        }
        let result = await state.sandbox.fetch(method: h.method, url: url, headers: headers, body: body,
                                               contentType: contentType)
        state.vars[h.as] = result.body
        state.vars["\(h.as).status"] = String(result.status)
        state.vars["\(h.as).ok"] = result.ok ? "true" : "false"
        state.vars["\(h.as).error"] = result.error
        if result.error == "run_timeout" { state.timedOut = true }
        if state.tracing {
            if let host = result.host, !state.hosts.contains(host) { state.hosts.append(host) }
            state.record(.init(path: path, kind: .http, status: result.ok ? .ok : .failed, host: result.host,
                               httpStatus: result.status == 0 ? nil : result.status, bytes: result.bytes,
                               redirectHops: result.hops, error: result.error.isEmpty ? nil : result.error))
        }
    }

    private func runExtract(_ e: RecipeAddOnManifest.ExtractStep, state: inout State, path: String) {
        let input = state.vars[e.from] ?? ""
        var found: String?
        if input.utf8.count <= RecipeRegex.maxInputBytes, !input.isEmpty {
            if let jp = e.jsonpath {
                if case .success(let template) = RecipeTemplate.parse(jp),
                   case .success(let path) = RecipeJSONPath.parse(template: template, values: state.vars),
                   let json = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed]) {
                    let strings = path.strings(in: json, limit: e.limit ?? RecipeJSONPath.maxResults)
                    if !strings.isEmpty { found = strings.joined(separator: ", ") }
                }
            } else if let rx = e.regex, RecipeRegex.issues(in: rx, needsCaptureGroup: true).isEmpty,
                      let regex = try? NSRegularExpression(pattern: rx) {
                if case .matched(let s) = RecipeRegex.firstCapture(of: regex, in: input, budget: regexBudget) {
                    found = s
                }
            }
        }
        let hit = found.flatMap { $0.isEmpty ? nil : $0 }
        let value = hit ?? render(e.fallback ?? "", state.vars, .plain)
        state.vars[e.as] = String(value.prefix(Self.maxExtractedLength))
        state.record(.init(path: path, kind: .extract, status: hit == nil ? .missed : .ok,
                           value: DryRunTrace.truncated(value)))
    }

    private func displayPayload(_ d: RecipeAddOnManifest.DisplayStep, _ vars: [String: String]) -> RecipeDisplayPayload? {
        guard let kind = RecipeAddOnManifest.DisplayStep.Kind(rawValue: d.kind) else { return nil }
        let cap = RecipeAddOnValidator.maxDisplayItems
        let title = String(render(d.title, vars, .plain).prefix(RecipeAddOnValidator.maxDisplayTitleLength))
        let items = (d.items ?? []).prefix(cap).map {
            String(render($0, vars, .plain).prefix(RecipeAddOnValidator.maxSayLength))
        }
        let markers: [RecipeDisplayPayload.Marker] = (d.markers ?? []).prefix(cap).compactMap { m in
            guard let lat = Double(render(m.lat, vars, .plain).trimmingCharacters(in: .whitespaces)),
                  let lon = Double(render(m.lon, vars, .plain).trimmingCharacters(in: .whitespaces)),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return .init(latitude: lat, longitude: lon,
                         label: String(render(m.label, vars, .plain).prefix(RecipeAddOnValidator.maxDisplayTitleLength)))
        }
        return RecipeDisplayPayload(kind: kind, title: title, items: Array(items), markers: markers)
    }

    // MARK: - `if`

    /// Whether an `if` takes its `then` branch. Unknown ops, and numeric ops whose sides don't both
    /// parse as finite numbers, take `else`.
    static func evaluate(_ w: RecipeAddOnManifest.IfStep, vars: [String: String]) -> Bool {
        let current = vars[w.var]
        let left = (current ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let right = ((try? RecipeTemplate.parse(w.value ?? "").get())?.render(vars, context: .plain) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch RecipeAddOnManifest.IfStep.Op(rawValue: w.op) {
        case .exists: return current != nil
        case .empty: return left.isEmpty
        case .equals: return left == right
        case .notEquals: return left != right
        case .contains: return !right.isEmpty && left.range(of: right, options: [.caseInsensitive]) != nil
        case .greater, .less:
            guard let a = Double(left), let b = Double(right), a.isFinite, b.isFinite else { return false }
            return w.op == "greater" ? a > b : a < b
        case nil: return false
        }
    }

    // MARK: - Rendering

    private func render(_ text: String, _ vars: [String: String], _ context: RecipeTemplate.Context) -> String {
        switch RecipeTemplate.parse(text) {
        case .success(let t): return t.render(vars, context: context)
        case .failure: return ""
        }
    }

    /// A JSON body with every string leaf rendered and escaped as a JSON string. Keys are literal
    /// and emitted in sorted order.
    static func serialise(_ value: RecipeAddOnManifest.JSONValue, _ vars: [String: String]) -> String {
        switch value {
        case .string(let s):
            let rendered = (try? RecipeTemplate.parse(s).get())?.render(vars, context: .jsonString) ?? ""
            return "\"\(rendered)\""
        case .number(let d): return d.isFinite ? RecipeJSONPath.numberText(d) : "null"
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map { serialise($0, vars) }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { key in
                "\"\(RecipeTemplate.jsonStringEscaped(key))\":" + serialise(o[key] ?? .null, vars)
            }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - Arguments

/// The model's arguments checked against a skill's declared parameters and screened for secrets.
enum RecipeArguments {

    struct Refusal: Error, Equatable, Sendable {
        let message: String
    }

    /// Typed and limit-checked values as text. The model can send anything, so this is checked at
    /// every run: wrong types, out-of-range numbers, over-long strings, values outside an `enum`
    /// or not matching a `pattern`, and missing required parameters refuse the run. Arguments the
    /// skill doesn't declare are dropped. An optional parameter that wasn't sent stays unset.
    static func check(_ arguments: [String: Any], against parameters: [RecipeAddOnManifest.Parameter],
                      regexBudget: TimeInterval) -> Result<[String: String], Refusal> {
        var out: [String: String] = [:]
        for p in parameters {
            guard let raw = arguments[p.name], !(raw is NSNull) else {
                if p.required { return .failure(.init(message: "\(p.name) is required")) }
                continue
            }
            switch p.kind {
            case .string:
                guard let s = raw as? String else { return .failure(.init(message: "\(p.name) must be text")) }
                guard s.count <= p.effectiveMaxLength else { return .failure(.init(message: "\(p.name) is too long")) }
                if let allowed = p.allowed, !allowed.contains(s) {
                    return .failure(.init(message: "\(p.name) must be one of \(allowed.joined(separator: ", "))"))
                }
                if let pattern = p.pattern {
                    guard RecipeRegex.issues(in: pattern, needsCaptureGroup: false).isEmpty,
                          let regex = try? NSRegularExpression(pattern: pattern),
                          RecipeRegex.matches(regex, s, budget: regexBudget) else {
                        return .failure(.init(message: "\(p.name) is not in the expected form"))
                    }
                }
                out[p.name] = s
            case .number, .integer:
                guard let d = number(raw) else { return .failure(.init(message: "\(p.name) must be a number")) }
                if p.kind == .integer, d != d.rounded() { return .failure(.init(message: "\(p.name) must be a whole number")) }
                if let lo = p.min, d < lo { return .failure(.init(message: "\(p.name) is below \(RecipeJSONPath.numberText(lo))")) }
                if let hi = p.max, d > hi { return .failure(.init(message: "\(p.name) is above \(RecipeJSONPath.numberText(hi))")) }
                out[p.name] = RecipeJSONPath.numberText(d)
            case .boolean:
                guard let b = boolean(raw) else { return .failure(.init(message: "\(p.name) must be true or false")) }
                out[p.name] = b ? "true" : "false"
            }
        }
        return .success(out)
    }

    enum ScreenOutcome: Equatable, Sendable {
        case passed([String: String])
        case blocked([String])
    }

    /// `EgressScreen` with `.redact`: a credential (a `.secret` pattern) blocks the run; any other
    /// hit (personal data) continues with the redacted values.
    static func screen(_ values: [String: String]) -> ScreenOutcome {
        let verdict = EgressScreen.evaluate(values, policy: .redact)
        let secretNames = Set(SecretPatterns.all.filter { $0.category == .secret }.map(\.name))
        let credentialHits = verdict.hits.filter { secretNames.contains($0) }
        if !credentialHits.isEmpty { return .blocked(credentialHits) }
        if let redacted = verdict.redactedArgs {
            return .passed(redacted.compactMapValues { $0 as? String })
        }
        return .passed(values)
    }

    private static func number(_ raw: Any) -> Double? {
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { return d }
        return nil
    }

    private static func boolean(_ raw: Any) -> Bool? {
        if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = raw as? String {
            switch s.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }
}
